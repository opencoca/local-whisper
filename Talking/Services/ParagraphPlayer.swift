import Foundation
import AVFoundation

/// Plays a multi-paragraph utterance by pre-rendering paragraph N+1
/// via the engine while paragraph N plays through AVAudioPlayer.
///
/// Three structural wins over v1.2.0's monolithic `say` path:
///
/// 1. **Ground-truth duration.** `AVAudioFile.length / sampleRate`
///    gives the exact playback time of each rendered paragraph.
///    The highlight interpolator divides this by word count instead
///    of estimating from `wpm * speedFactor`. Per-paragraph drift
///    stays bounded by the interpolator's word-uniformity assumption,
///    not by speed-factor calibration error.
///
/// 2. **Drift never accumulates.** Each paragraph's timer is anchored
///    fresh at its own playback start. Whatever error existed in
///    paragraph N's interpolation gets discarded when paragraph N+1
///    begins.
///
/// 3. **Near-zero inter-paragraph latency.** Render-ahead concurrency
///    means paragraph N+1's AIFF is already on disk by the time
///    paragraph N finishes playing (say renders much faster than
///    realtime). The AVAudioPlayer swap is essentially instantaneous.
///
/// Engine-agnostic: any `ParagraphRenderEngine` plugs in. v1.2.1
/// ships with `SayRenderEngine`; v1.3 adds `KokoroRenderEngine` via
/// the same interface.
actor ParagraphPlayer {

    // MARK: - Configuration

    private let engine: ParagraphRenderEngine
    private let progressContinuation: AsyncStream<(UInt64, Double)>.Continuation
    private let rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation
    private let paragraphContinuation: AsyncStream<(UInt64, Int, Int)>.Continuation

    // MARK: - Active utterance state

    private var utteranceID: UInt64 = 0
    private var paragraphs: [String] = []
    private var paragraphCharOffsets: [Int] = []
    private var voiceID: String?
    private var rate: Float = 0.5

    private var currentIndex: Int = 0
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?

    // Render-ahead Task for paragraph N+1 while N plays.
    private var renderAheadTask: Task<RenderedParagraph?, Never>?

    // Highlight interpolator ticker for the currently playing paragraph.
    private var highlightTask: Task<Void, Never>?

    // Per-paragraph timing. `currentDuration` is the AIFF's true
    // duration (used as denominator for word-position interpolation);
    // the playhead position itself comes from
    // `AVAudioPlayer.currentTime` so we don't have to maintain a
    // parallel wall-clock anchor that could race the actor's queue.
    private var currentDuration: TimeInterval = 0
    private var isPaused: Bool = false

    // Temp files awaiting cleanup. Tracked here so stop() can sweep
    // them even if the loop is mid-paragraph.
    private var pendingTempFiles: Set<URL> = []

    // Continuation the AVAudioPlayer delegate resolves when the current
    // paragraph finishes. `nil` between paragraphs.
    private var playbackCompletion: CheckedContinuation<Bool, Never>?

    // MARK: - Init

    init(
        engine: ParagraphRenderEngine,
        progressContinuation: AsyncStream<(UInt64, Double)>.Continuation,
        rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation,
        paragraphContinuation: AsyncStream<(UInt64, Int, Int)>.Continuation
    ) {
        self.engine = engine
        self.progressContinuation = progressContinuation
        self.rangeContinuation = rangeContinuation
        self.paragraphContinuation = paragraphContinuation
    }

    // MARK: - Public surface

    /// Play the paragraph queue end to end. Returns when the last
    /// paragraph finishes naturally, throws if any render or playback
    /// fails, returns normally on `stop()` (the half-complete utterance
    /// is left to the caller's read-along teardown).
    func start(
        paragraphs: [String],
        voiceID: String?,
        rate: Float,
        utteranceID: UInt64,
        fullText: String
    ) async throws {
        guard !paragraphs.isEmpty else { return }

        self.paragraphs = paragraphs
        self.paragraphCharOffsets = Self.computeCharOffsets(of: paragraphs, in: fullText)
        self.voiceID = voiceID
        self.rate = rate
        self.utteranceID = utteranceID
        self.currentIndex = 0
        self.isPaused = false

        progressContinuation.yield((utteranceID, 0.0))

        // Pre-render paragraph 0 (the loop expects renderAheadTask to
        // hold paragraph N's render when N starts).
        kickRenderAhead(for: 0)

        for index in 0 ..< paragraphs.count {
            try Task.checkCancellation()
            currentIndex = index
            paragraphContinuation.yield((utteranceID, index, paragraphs.count))

            let rendered = try await awaitOrRender(index: index)
            pendingTempFiles.insert(rendered.audioFileURL)

            // Kick off pre-render for index + 1 before starting playback
            // of index, so they overlap on the wall clock.
            kickRenderAhead(for: index + 1)

            try await playOneParagraph(index: index, rendered: rendered)

            try? FileManager.default.removeItem(at: rendered.audioFileURL)
            pendingTempFiles.remove(rendered.audioFileURL)

            // Per-utterance progress: paragraphs completed / total.
            let outerProgress = Double(index + 1) / Double(paragraphs.count)
            progressContinuation.yield((utteranceID, outerProgress))
        }
    }

    func pause() {
        guard !isPaused else { return }
        player?.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        player?.play()
    }

    func stop() {
        // Cancel all in-flight work first so race-y delegate callbacks
        // that fire during teardown become no-ops.
        highlightTask?.cancel()
        highlightTask = nil
        renderAheadTask?.cancel()
        renderAheadTask = nil

        player?.stop()
        player = nil
        playerDelegate = nil

        cleanupPendingTempFiles()

        // Resolve the playback continuation if one is in flight; the
        // outer loop will then break on the next cancellation check.
        if let cont = playbackCompletion {
            playbackCompletion = nil
            cont.resume(returning: false)
        }
    }

    // MARK: - Paragraph index → fullText character offset

    nonisolated private static func computeCharOffsets(of paragraphs: [String], in fullText: String) -> [Int] {
        // Walk forward through fullText finding each paragraph in
        // sequence. Used to translate per-paragraph word ranges into
        // fullText coordinates that LargeLiveTranscriptionView's
        // sentence centering expects.
        let ns = fullText as NSString
        var cursor = 0
        var offsets: [Int] = []
        for p in paragraphs {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let found = ns.range(of: p, options: [], range: searchRange)
            if found.location != NSNotFound {
                offsets.append(found.location)
                cursor = found.location + found.length
            } else {
                // Fallback: append at cursor. The fallback path
                // shouldn't fire in practice (TextSplitter outputs
                // substrings of fullText after whitespace normalisation),
                // but guards against ever returning a mis-sized array.
                offsets.append(cursor)
                cursor += (p as NSString).length
            }
        }
        return offsets
    }

    // MARK: - Render-ahead

    private func kickRenderAhead(for index: Int) {
        guard index < paragraphs.count else {
            renderAheadTask = nil
            return
        }
        let paragraph = paragraphs[index]
        let voice = voiceID
        let r = rate
        let eng = engine
        renderAheadTask = Task {
            try? await eng.render(paragraph: paragraph, voiceID: voice, rate: r)
        }
    }

    private func awaitOrRender(index: Int) async throws -> RenderedParagraph {
        if let task = renderAheadTask, let pre = await task.value {
            renderAheadTask = nil
            return pre
        }
        // Fall back to a fresh synchronous render if the pre-render
        // failed or wasn't scheduled.
        renderAheadTask = nil
        return try await engine.render(
            paragraph: paragraphs[index],
            voiceID: voiceID,
            rate: rate
        )
    }

    // MARK: - Play one paragraph

    private func playOneParagraph(index: Int, rendered: RenderedParagraph) async throws {
        let p = try AVAudioPlayer(contentsOf: rendered.audioFileURL)
        player = p
        currentDuration = rendered.duration
        isPaused = false

        let delegate = PlayerDelegate { [weak self] success in
            Task { await self?.finishParagraph(success: success) }
        }
        playerDelegate = delegate
        p.delegate = delegate
        p.prepareToPlay()
        p.play()

        startHighlightTimer(
            paragraph: paragraphs[index],
            offset: paragraphCharOffsets[index],
            timings: rendered.phonemeTimings
        )

        // Park here until the delegate resolves the continuation
        // (natural finish, or stop() poking it false).
        let finishedNaturally = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.playbackCompletion = cont
        }

        highlightTask?.cancel()
        highlightTask = nil
        player = nil
        playerDelegate = nil

        if !finishedNaturally {
            throw CancellationError()
        }
    }

    private func finishParagraph(success: Bool) {
        if let cont = playbackCompletion {
            playbackCompletion = nil
            cont.resume(returning: success)
        }
    }

    // MARK: - Highlight interpolator

    private func startHighlightTimer(paragraph: String, offset: Int, timings: PhonemeTimings?) {
        // Phoneme-timing path (v1.3, when the engine surfaces them).
        // For v1.2.1 say this is always nil; fall through to the
        // word-uniformity interpolator anchored to ground-truth
        // duration.
        _ = timings

        let words = enumerateWordRanges(in: paragraph, offset: offset)
        guard !words.isEmpty else { return }

        let total = currentDuration
        let utt = utteranceID

        highlightTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let now = Date()
                // Atomic single actor-hop. Reading paragraphStartedAt,
                // paragraphPausedDuration, paragraphPauseStartedAt as
                // three separate `await self.x` reads gave pause() a
                // window to land between them — the resulting mixed
                // snapshot under-reported pausedSoFar and the highlight
                // kept advancing despite the user clicking Pause.
                let done = await self.highlightTick(
                    now: now,
                    words: words,
                    total: total,
                    utteranceID: utt
                )
                if done { return }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// Compute the current word range from `AVAudioPlayer.currentTime`
    /// — the audio playhead, frozen during pause, resumes correctly
    /// after `play()`. Using it eliminates the manual
    /// paragraphStartedAt / paragraphPausedDuration /
    /// paragraphPauseStartedAt bookkeeping that introduced a pause
    /// race in the first cut. The delegate (`finishParagraph`) handles
    /// the end-of-paragraph signal; this tick keeps running until the
    /// task is cancelled by `playOneParagraph`'s teardown.
    private func highlightTick(
        now: Date,
        words: [NSRange],
        total: TimeInterval,
        utteranceID: UInt64
    ) -> Bool {
        guard let p = player else { return true }
        let elapsed = p.currentTime
        let progress = total > 0 ? min(1.0, elapsed / total) : 1.0
        let wordIdx = min(words.count - 1, Int(progress * Double(words.count)))
        rangeContinuation.yield((utteranceID, words[wordIdx]))
        // Return false so the loop keeps polling until the delegate
        // fires and `playOneParagraph` cancels the task. Bailing on
        // `progress >= 1.0` here would leave the last word un-yielded
        // for the brief gap between currentTime hitting duration and
        // the delegate's audioPlayerDidFinishPlaying callback.
        return false
    }

    private nonisolated func enumerateWordRanges(in paragraph: String, offset: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = paragraph as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords, .localized]
        ) { _, range, _, _ in
            ranges.append(NSRange(location: range.location + offset, length: range.length))
        }
        return ranges
    }

    // MARK: - Cleanup

    private func cleanupPendingTempFiles() {
        for url in pendingTempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        pendingTempFiles.removeAll()
    }

    // MARK: - Inner: AVAudioPlayer delegate

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let onFinish: @Sendable (Bool) -> Void
        init(onFinish: @escaping @Sendable (Bool) -> Void) {
            self.onFinish = onFinish
        }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish(flag)
        }
    }
}
