import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AppKit  // For NSSpeechSynthesizer (legacy framework still drives `say`)

/// Wraps macOS's TTS engines for the speak lane. Mirrors
/// `TranscriptionService`'s actor + progress-stream shape so the two
/// lanes can be reasoned about symmetrically.
///
/// Two engines under one actor:
/// - **AVSpeechSynthesizer** (modern, cross-platform) — sees voices
///   Apple exposes to third-party apps: Premium / Enhanced
///   (Siri-quality, neural) and the Default compact set.
/// - **NSSpeechSynthesizer** (legacy AppKit, deprecated in macOS 14
///   but still functional, same engine `say` uses) — sees a *superset*
///   including regional / novelty voices that AV filters out.
///
/// Both engines provide per-word range callbacks, so read-along works
/// regardless of which one a given voice belongs to. `speak()` decodes
/// the engine prefix from the voice ID (`"av:..."` / `"ns:..."`) and
/// dispatches.
///
/// Streams:
/// - `progressStream` — `(utteranceID, 0...1)` from both engines.
/// - `rangeStream` — `(utteranceID, NSRange)` of the currently spoken
///   word. Drives the read-along highlight.
///
/// Playback API is one-utterance-at-a-time: calling `speak(...)` while
/// another utterance is in flight cancels the previous one across both
/// engines and starts the new one.
actor SpeakService {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: Delegate?
    private var nsSynth: NSSpeechSynthesizer?
    private var nsDelegate: NSSpeakDelegate?
    /// Power-user backend: `/usr/bin/say` running as a subprocess.
    /// Only one of `synthesizer` / `nsSynth` / `sayProcess` is active
    /// at a time (the dispatcher in `speak()` preempts the others).
    private var sayProcess: Process?
    /// Time-driven read-along simulator for the say backend. `say`
    /// gives us no per-word callback, so we estimate the current
    /// word from elapsed time × wpm, accounting for SIGSTOP pauses.
    private var sayHighlightTask: Task<Void, Never>?
    private var saySpeakingStartedAt: Date?
    private var sayPauseStartedAt: Date?
    private var sayTotalPausedDuration: TimeInterval = 0
    /// v1.2.1 paragraph-chunked say lane. Non-nil only while a
    /// multi-paragraph utterance is in flight. Exactly one of
    /// `sayProcess` and `paragraphPlayer` is non-nil at a time —
    /// the fast-path in `speakViaSayCommand` decides which.
    private var paragraphPlayer: ParagraphPlayer?
    private var paragraphPlayerTask: Task<Void, Error>?
    private var currentEngine: SpeechEngine?
    private var activeContinuation: CheckedContinuation<Void, Error>?

    /// v1.3 Kokoro backend. AppState injects the shared instance so
    /// `KokoroService.stateStream` reaches `@Published kokoroDownloadState`
    /// on the UI side. Optional so the legacy `SpeakService()` ctor still
    /// works for tests / one-offs that don't need Kokoro.
    private let kokoroService: KokoroService?

    /// Monotonically-increasing utterance id. The delegate closes over
    /// the id it was installed with and tags every stream yield, so the
    /// coordinator can drop yields from a preempted utterance whose
    /// callbacks arrive after the next one has started.
    private var nextUtteranceID: UInt64 = 0

    private let progressContinuation: AsyncStream<(UInt64, Double)>.Continuation
    nonisolated let progressStream: AsyncStream<(UInt64, Double)>

    private let rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation
    nonisolated let rangeStream: AsyncStream<(UInt64, NSRange)>

    /// v1.2.1 paragraph-progress stream. Yields `(utteranceID,
    /// paragraphIndex, paragraphCount)` at each paragraph boundary
    /// from the chunked say lane (and v1.3 Kokoro). AV/NS/single-
    /// paragraph say never yield here. Coordinator forwards updates
    /// to `appState.speakState` so the read-along footer can render
    /// "Paragraph N / M".
    private let paragraphContinuation: AsyncStream<(UInt64, Int, Int)>.Continuation
    nonisolated let paragraphStream: AsyncStream<(UInt64, Int, Int)>

    init(kokoroService: KokoroService? = nil) {
        var pc: AsyncStream<(UInt64, Double)>.Continuation!
        self.progressStream = AsyncStream { pc = $0 }
        self.progressContinuation = pc

        var rc: AsyncStream<(UInt64, NSRange)>.Continuation!
        self.rangeStream = AsyncStream { rc = $0 }
        self.rangeContinuation = rc

        var qc: AsyncStream<(UInt64, Int, Int)>.Continuation!
        self.paragraphStream = AsyncStream { qc = $0 }
        self.paragraphContinuation = qc

        self.kokoroService = kokoroService
    }

    /// Returns the installed system voices from the AV catalog only.
    /// Existing call site that wants the legacy-shape list. New UI
    /// should use `availableVoiceInfos()` to get the merged catalog.
    func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    /// Returns the merged catalog from both engines. NS voices that
    /// duplicate an AV identifier are dropped (AV wins because it
    /// provides richer metadata). NS-only voices are kept with their
    /// engine tag — these are mostly regional voices (Aman, Tara,
    /// Ona…) and novelty voices (Bad News, Cellos, Wobble…) that
    /// AVSpeech deliberately filters out but are reachable through
    /// NSSpeechSynthesizer / `say`.
    func availableVoiceInfos() -> [SpeakVoiceInfo] {
        let avInfos: [SpeakVoiceInfo] = AVSpeechSynthesisVoice.speechVoices().map { v in
            let q: SpeakVoiceInfo.Quality
            switch v.quality {
            case .premium: q = .premium
            case .enhanced: q = .enhanced
            default: q = .default
            }
            var isPersonal = false
            if #available(macOS 14.0, *) {
                isPersonal = v.voiceTraits.contains(.isPersonalVoice)
            }
            return SpeakVoiceInfo(
                engine: .avSpeechSynthesizer,
                identifier: v.identifier,
                name: v.name,
                language: v.language,
                quality: q,
                isPersonalVoice: isPersonal
            )
        }
        let avIDs = Set(avInfos.map(\.identifier))
        let nsInfos: [SpeakVoiceInfo] = NSSpeechSynthesizer.availableVoices.compactMap { vname in
            let id = vname.rawValue
            if avIDs.contains(id) { return nil }
            let attrs = NSSpeechSynthesizer.attributes(forVoice: vname)
            let displayName = (attrs[.name] as? String) ?? id
            let lang = (attrs[.localeIdentifier] as? String)?.replacingOccurrences(of: "_", with: "-") ?? "?"
            let q: SpeakVoiceInfo.Quality
            if id.contains(".premium.") { q = .premium }
            else if id.contains(".enhanced.") { q = .enhanced }
            else { q = .default }
            return SpeakVoiceInfo(
                engine: .nsSpeechSynthesizer,
                identifier: id,
                name: displayName,
                language: lang,
                quality: q,
                isPersonalVoice: false
            )
        }
        // v1.3 Kokoro voices are surfaced at .premium quality. The
        // catalog is static (single curated entry for v1.3 — see
        // `KokoroService.curatedVoices`); we don't need the actor to
        // be loaded to list them.
        let kokoroInfos: [SpeakVoiceInfo] = KokoroService.curatedVoices.map { v in
            SpeakVoiceInfo(
                engine: .kokoro,
                identifier: v.id,
                name: "\(v.displayName) (\(v.gender == "Female" ? "\u{2640}" : "\u{2642}"))",
                language: v.accent,
                quality: .premium,
                isPersonalVoice: false
            )
        }
        return avInfos + nsInfos + kokoroInfos
    }

    /// Start playback. Returns when the synthesizer reports `didFinish`
    /// or `didCancel` for the *passed* utterance — i.e. the call awaits
    /// until either speech completes or another `speak()`/`stop()`
    /// supersedes it. Throws only for upstream configuration errors;
    /// cancellation is a successful return.
    ///
    /// `voiceID` may be:
    /// - `nil` or empty → AV default voice
    /// - `"av:<identifier>"` → explicit AVSpeech voice
    /// - `"ns:<identifier>"` → NSSpeechSynthesizer voice (the
    ///   `say`-catalog superset)
    /// - bare identifier (legacy stored value) → assumed AV
    ///
    /// `useSayCommand` is the orthogonal power-user override: when
    /// `true`, the in-process engines are bypassed and `/usr/bin/say`
    /// is spawned as a subprocess regardless of the voice's engine
    /// prefix. Loses read-along highlighting (no per-word callback)
    /// but reaches whatever Apple's daemon exposes to the CLI tool.
    ///
    /// `sayColdStartLag` / `saySpeedFactor` calibrate the
    /// time-driven highlight simulator that runs alongside the
    /// `say` subprocess (see `startSayHighlightSimulation`). Both
    /// are user-tunable in Settings → Voice when the say toggle
    /// is on; defaults are 0.18 s and 1.15.
    func speak(
        text: String,
        voiceID: String?,
        rate: Float,
        pitch: Float,
        useSayCommand: Bool = false,
        sayColdStartLag: TimeInterval = 0.18,
        saySpeedFactor: Double = 1.15
    ) async throws {
        let (engine, id) = Self.decodeVoiceID(voiceID)

        // Engine prefix wins. `useSayCommand` is the AV/NS power-user
        // override — it routes voices that *belong* to the Apple TTS
        // daemon through the `say` CLI. Future engines (Kokoro,
        // Chatterbox) have their own audio pipeline and must not be
        // hijacked by the toggle. The exhaustive switch below forces
        // every new engine case to declare whether it honours
        // `useSayCommand` or runs through its native path.
        if useSayCommand {
            switch engine {
            case .avSpeechSynthesizer, .nsSpeechSynthesizer:
                try await speakViaSayCommand(
                    text: text,
                    voiceID: id,
                    rate: rate,
                    coldStartLag: sayColdStartLag,
                    speedFactor: saySpeedFactor
                )
                return
            case .kokoro:
                // Kokoro owns its own audio pipeline — the say toggle
                // is a no-op for it. Fall through to the native path.
                break
            }
        }

        switch engine {
        case .avSpeechSynthesizer:
            try await speakViaAV(text: text, voiceID: id, rate: rate, pitch: pitch)
        case .nsSpeechSynthesizer:
            try await speakViaNS(text: text, voiceID: id, rate: rate)
        case .kokoro:
            try await speakViaKokoro(
                text: text,
                voiceID: id,
                rate: rate,
                coldStartLag: sayColdStartLag,
                speedFactor: saySpeedFactor
            )
        }
    }

    private func speakViaAV(text: String, voiceID: String?, rate: Float, pitch: Float) async throws {
        // Preempt any in-flight utterance. Order matters: we MUST resume
        // and clear `activeContinuation` for the prior call BEFORE the
        // new `withCheckedThrowingContinuation` assigns its own. The
        // delegate's didCancel arrives asynchronously and would otherwise
        // resume *the new* continuation, returning the new speak() call
        // immediately while audio plays on and leaking the prior
        // continuation (`SWIFT TASK CONTINUATION MISUSE`).
        if let synth = synthesizer, synth.isSpeaking || synth.isPaused {
            let prior = activeContinuation
            activeContinuation = nil
            synth.stopSpeaking(at: .immediate)
            prior?.resume(returning: ())
        }
        // Also preempt any NS utterance that may be running — only one
        // engine speaks at a time.
        if let s = nsSynth, s.isSpeaking {
            let prior = activeContinuation
            activeContinuation = nil
            s.stopSpeaking()
            prior?.resume(returning: ())
        }

        nextUtteranceID &+= 1
        let myID = nextUtteranceID
        let utterance = makeUtterance(text: text, voiceID: voiceID, rate: rate, pitch: pitch)
        let synth = synthesizer ?? AVSpeechSynthesizer()
        let del = installDelegate(on: synth, utteranceLength: text.utf16.count, utteranceID: myID)
        delegate = del
        synthesizer = synth
        currentEngine = .avSpeechSynthesizer

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            synth.speak(utterance)
        }
    }

    private func speakViaNS(text: String, voiceID: String?, rate: Float) async throws {
        // Mirror the AV preempt for both possible in-flight engines.
        if let s = nsSynth, s.isSpeaking {
            let prior = activeContinuation
            activeContinuation = nil
            s.stopSpeaking()
            prior?.resume(returning: ())
        }
        if let synth = synthesizer, synth.isSpeaking || synth.isPaused {
            let prior = activeContinuation
            activeContinuation = nil
            synth.stopSpeaking(at: .immediate)
            prior?.resume(returning: ())
        }

        nextUtteranceID &+= 1
        let myID = nextUtteranceID
        let s = nsSynth ?? NSSpeechSynthesizer()
        let del = NSSpeakDelegate(
            utteranceID: myID,
            progressContinuation: progressContinuation,
            rangeContinuation: rangeContinuation,
            utteranceLength: text.utf16.count,
            onComplete: { [weak self] in
                Task { await self?.resolveActiveContinuation() }
            }
        )
        s.delegate = del
        if let voiceID, !voiceID.isEmpty {
            _ = s.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceID))
        }
        // NSSpeechSynthesizer rate is words per minute. Map our
        // normalised 0...1 onto 100...400 wpm so the perceived range
        // roughly matches AV's slider.
        s.rate = 100 + rate * 300
        nsSynth = s
        nsDelegate = del
        currentEngine = .nsSpeechSynthesizer

        // Eagerly emit didStart's progress — NS's delegate doesn't fire
        // a didStart callback like AV does, only willSpeakWord.
        progressContinuation.yield((myID, 0.0))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            _ = s.startSpeaking(text)
        }
    }

    /// Power-user backend. Spawns `/usr/bin/say` as a subprocess and
    /// pipes the text in via stdin (no shell escaping, no injection
    /// risk). Pause/resume use SIGSTOP / SIGCONT; stop sends SIGTERM
    /// after first SIGCONT'ing in case the process is paused (else
    /// SIGTERM is queued behind the pause and never delivers).
    ///
    /// No per-word callback is available from `say`, so the range
    /// stream stays silent and the progress stream just emits
    /// `(0.0)` at start and `(1.0)` on exit. Read-along works in
    /// principle (the modal still opens with the source text) but
    /// the active-word highlight stays absent — caller's choice.
    private func speakViaSayCommand(
        text: String,
        voiceID: String?,
        rate: Float,
        coldStartLag: TimeInterval,
        speedFactor: Double
    ) async throws {
        // v1.2.1 fast-path: route multi-paragraph input through the
        // ParagraphPlayer (pre-render + AVAudioPlayer + per-paragraph
        // ground-truth-duration interpolator). Single-paragraph input
        // falls through to the legacy direct-Process path below, which
        // keeps the calibration sliders relevant for short utterances.
        let paragraphs = TextSplitter.paragraphs(from: text)
        if paragraphs.count > 1 {
            try await speakViaParagraphChunker(
                paragraphs: paragraphs,
                voiceID: voiceID,
                rate: rate,
                fullText: text
            )
            return
        }

        // Preempt across all three backends.
        preemptInFlight()

        nextUtteranceID &+= 1
        let myID = nextUtteranceID

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let id = voiceID, !id.isEmpty {
            args.append("-v")
            args.append(id)
        }
        // say's -r is words-per-minute. Same mapping NS uses.
        let wpm = Int((100 + rate * 300).rounded())
        args.append("-r")
        args.append(String(wpm))
        proc.arguments = args

        let stdin = Pipe()
        proc.standardInput = stdin
        // /dev/null the output so we don't leak the daemon's logs.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            // Hop back to the actor; can't touch its state from here.
            Task { [weak self] in
                await self?.sayCommandDidTerminate(utteranceID: myID)
            }
        }

        sayProcess = proc
        currentEngine = nil  // Sentinel: pause/stop check sayProcess first.
        progressContinuation.yield((myID, 0.0))
        startSayHighlightSimulation(
            utteranceID: myID,
            text: text,
            wpm: wpm,
            coldStartLag: coldStartLag,
            speedFactor: speedFactor
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            do {
                try proc.run()
            } catch {
                activeContinuation = nil
                sayProcess = nil
                stopSayHighlightSimulation()
                cont.resume(throwing: error)
                return
            }
            // Pipe the text in. Closing the write side signals EOF so
            // `say` knows where the text ends.
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
        }
    }

    fileprivate func sayCommandDidTerminate(utteranceID: UInt64) {
        stopSayHighlightSimulation()
        progressContinuation.yield((utteranceID, 1.0))
        sayProcess = nil
        resolveActiveContinuation()
    }

    /// v1.2.1 chunked say lane. Routes multi-paragraph input through
    /// `ParagraphPlayer` so each paragraph plays from a pre-rendered
    /// AIFF whose true duration anchors the highlight interpolator.
    /// Calibration sliders (`sayColdStartLag`, `saySpeedFactor`) don't
    /// apply here — the player computes word timing from
    /// `AVAudioFile`'s actual frame count.
    private func speakViaParagraphChunker(
        paragraphs: [String],
        voiceID: String?,
        rate: Float,
        fullText: String
    ) async throws {
        preemptInFlight()

        nextUtteranceID &+= 1
        let myID = nextUtteranceID

        let player = ParagraphPlayer(
            engine: SayRenderEngine(speakService: self),
            progressContinuation: progressContinuation,
            rangeContinuation: rangeContinuation,
            paragraphContinuation: paragraphContinuation
        )
        paragraphPlayer = player
        currentEngine = nil  // Sentinel — preempt/pause/stop check paragraphPlayer first.

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            paragraphPlayerTask = Task { [weak self] in
                do {
                    try await player.start(
                        paragraphs: paragraphs,
                        voiceID: voiceID,
                        rate: rate,
                        utteranceID: myID,
                        fullText: fullText
                    )
                    await self?.paragraphPlayerDidFinish(success: true, error: nil)
                } catch {
                    await self?.paragraphPlayerDidFinish(success: false, error: error)
                }
            }
        }
    }

    /// v1.3 Kokoro lane. Routes through `ParagraphPlayer` with a
    /// `KokoroRenderEngine` so the read-along + paragraph progress
    /// machinery is shared with the chunked-say path. Kokoro
    /// pre-renders each paragraph to a 24 kHz mono WAV on disk;
    /// `AVAudioPlayer.duration` then drives word-uniformity
    /// interpolation. `coldStartLag` / `speedFactor` are honoured so
    /// the user's calibration sliders apply to Kokoro too.
    private func speakViaKokoro(
        text: String,
        voiceID: String?,
        rate: Float,
        coldStartLag: TimeInterval,
        speedFactor: Double
    ) async throws {
        guard let kokoroService else {
            throw SpeakError.kokoroUnavailable
        }
        preemptInFlight()

        nextUtteranceID &+= 1
        let myID = nextUtteranceID

        let paragraphs = TextSplitter.paragraphs(from: text)
        let chunks = paragraphs.isEmpty ? [text] : paragraphs

        let player = ParagraphPlayer(
            engine: KokoroRenderEngine(service: kokoroService),
            progressContinuation: progressContinuation,
            rangeContinuation: rangeContinuation,
            paragraphContinuation: paragraphContinuation
        )
        paragraphPlayer = player
        currentEngine = nil  // Sentinel — paragraphPlayer owns this utterance.

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            paragraphPlayerTask = Task { [weak self] in
                do {
                    try await player.start(
                        paragraphs: chunks,
                        voiceID: voiceID,
                        rate: rate,
                        utteranceID: myID,
                        fullText: text
                    )
                    await self?.paragraphPlayerDidFinish(success: true, error: nil)
                } catch {
                    await self?.paragraphPlayerDidFinish(success: false, error: error)
                }
            }
        }
        _ = coldStartLag
        _ = speedFactor
    }

    /// Offline-render path for Save Speech As… on Kokoro voices.
    /// Synthesizes the full text in one pass and loads the resulting
    /// WAV through the same AVAudioFile pipeline that the say / NS
    /// render paths use, so `AudioExporter` sees identical input
    /// regardless of engine.
    private func renderViaKokoro(text: String, voiceID: String?, rate: Float) async throws -> AudioData {
        guard let kokoroService else {
            throw SpeakError.kokoroUnavailable
        }
        let rendered = try await kokoroService.synthesize(text: text, voiceID: voiceID, rate: rate)
        defer { try? FileManager.default.removeItem(at: rendered.audioFileURL) }
        return try loadAudioData(fromAIFFAt: rendered.audioFileURL)
    }

    fileprivate func paragraphPlayerDidFinish(success: Bool, error: Error?) {
        paragraphPlayer = nil
        paragraphPlayerTask = nil
        let prior = activeContinuation
        activeContinuation = nil
        if let error, !success {
            prior?.resume(throwing: error)
        } else {
            prior?.resume(returning: ())
        }
    }

    // MARK: - Say highlight simulator (time-driven, no per-word callback)

    /// Start a Task that ticks every 80 ms and yields a range/progress
    /// pair to the streams, estimating the current word from elapsed
    /// time × the wpm we passed `say`. Pauses correctly: SIGSTOP
    /// suspends both audio and our elapsed counter via
    /// `sayPauseStartedAt`. Cancellation comes from
    /// `stopSayHighlightSimulation` (terminate / preempt) or when the
    /// process termination handler fires.
    ///
    /// `coldStartLag` pins the simulator to word 0 for that many
    /// seconds (compensates for the process-launch / audio-engine
    /// delay between `proc.run()` and the first audible sample).
    /// `speedFactor` multiplies the requested wpm so the simulated
    /// rate matches what `say` actually delivers — Premium / Siri
    /// voices commonly run 1.10–1.20× the `-r` target.
    private func startSayHighlightSimulation(
        utteranceID: UInt64,
        text: String,
        wpm: Int,
        coldStartLag: TimeInterval,
        speedFactor: Double
    ) {
        // Anchor the elapsed counter `coldStartLag` into the future.
        // The first ~coldStartLag of ticks see negative elapsed
        // (clamped to 0), so the highlight pins to word 0 until
        // audio actually starts.
        saySpeakingStartedAt = Date().addingTimeInterval(coldStartLag)
        sayPauseStartedAt = nil
        sayTotalPausedDuration = 0

        // One-pass word-range enumeration. NSString.enumerateSubstrings
        // with `.byWords` gives us the character ranges of every word
        // — exactly what AV's willSpeakRange callback delivers, just
        // without timing info.
        var wordRanges: [NSRange] = []
        let nsText = text as NSString
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byWords, .localized]
        ) { _, range, _, _ in
            wordRanges.append(range)
        }
        guard !wordRanges.isEmpty else { return }
        let frozen = wordRanges
        let totalWords = Double(frozen.count)
        // Inflate the requested wpm by the empirical speed factor so
        // our simulated rate matches the rate `say` actually delivers
        // (the requested -r is a target, not a guarantee).
        let calibratedWPM = Double(wpm) * speedFactor
        // Floor at 0.5 s so a one-word utterance doesn't divide by ~0.
        let expectedDuration = max(0.5, totalWords / calibratedWPM * 60.0)

        sayHighlightTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { return }
                await self?.sayHighlightTick(
                    utteranceID: utteranceID,
                    wordRanges: frozen,
                    expectedDuration: expectedDuration
                )
            }
        }
    }

    private func sayHighlightTick(utteranceID: UInt64, wordRanges: [NSRange], expectedDuration: TimeInterval) {
        guard sayProcess?.isRunning == true,
              let startedAt = saySpeakingStartedAt else { return }

        let now = Date()
        var elapsed = now.timeIntervalSince(startedAt) - sayTotalPausedDuration
        if let pausedAt = sayPauseStartedAt {
            // Don't advance while paused — extend the "paused
            // duration" up to now.
            elapsed -= now.timeIntervalSince(pausedAt)
        }
        elapsed = max(0, elapsed)

        let progress = min(elapsed / expectedDuration, 1.0)
        let wordIdx = min(Int(progress * Double(wordRanges.count)), wordRanges.count - 1)
        let range = wordRanges[wordIdx]

        rangeContinuation.yield((utteranceID, range))
        progressContinuation.yield((utteranceID, progress))
    }

    private func stopSayHighlightSimulation() {
        sayHighlightTask?.cancel()
        sayHighlightTask = nil
        saySpeakingStartedAt = nil
        sayPauseStartedAt = nil
        sayTotalPausedDuration = 0
    }

    /// Preempt any in-flight utterance from any backend before starting
    /// a new one. Resumes the active continuation eagerly so the
    /// late-arriving completion callback sees `activeContinuation == nil`
    /// and is a no-op (same poka-yoke as the AV/NS preempt paths).
    private func preemptInFlight() {
        if let synth = synthesizer, synth.isSpeaking || synth.isPaused {
            let prior = activeContinuation
            activeContinuation = nil
            synth.stopSpeaking(at: .immediate)
            prior?.resume(returning: ())
        }
        if let s = nsSynth, s.isSpeaking {
            let prior = activeContinuation
            activeContinuation = nil
            s.stopSpeaking()
            prior?.resume(returning: ())
        }
        if let p = sayProcess, p.isRunning {
            let prior = activeContinuation
            activeContinuation = nil
            // SIGCONT first in case it was paused, else SIGTERM is
            // queued behind the stop and never delivers.
            kill(p.processIdentifier, SIGCONT)
            p.terminate()
            sayProcess = nil
            stopSayHighlightSimulation()
            prior?.resume(returning: ())
        }
        if let player = paragraphPlayer {
            let prior = activeContinuation
            activeContinuation = nil
            paragraphPlayerTask?.cancel()
            paragraphPlayerTask = nil
            paragraphPlayer = nil
            // Fire-and-forget the player tear-down; its own stop()
            // resolves the paragraphPlayerDidFinish callback into a
            // no-op now that activeContinuation is already nil.
            Task { await player.stop() }
            prior?.resume(returning: ())
        }
    }

    /// Pause the active utterance at the next word boundary. No-op if
    /// nothing is playing. For the `say` subprocess backend, this is
    /// SIGSTOP — the kernel suspends the process, audio cuts
    /// immediately at the kernel boundary (not at a word boundary
    /// like the in-process engines). The highlight simulator's
    /// elapsed counter is paused too so the active word doesn't
    /// drift forward while audio is suspended.
    func pause() async {
        if let player = paragraphPlayer {
            // Synchronously await so the highlight task observes the
            // pause anchor on its next tick. A fire-and-forget Task
            // races the highlight task and lets the highlight advance
            // one or two more words before freezing.
            await player.pause()
            return
        }
        if let p = sayProcess, p.isRunning {
            kill(p.processIdentifier, SIGSTOP)
            if sayPauseStartedAt == nil {
                sayPauseStartedAt = Date()
            }
            return
        }
        switch currentEngine {
        case .avSpeechSynthesizer:
            synthesizer?.pauseSpeaking(at: .word)
        case .nsSpeechSynthesizer:
            nsSynth?.pauseSpeaking(at: .wordBoundary)
        case .kokoro:
            // Unreachable — the Kokoro lane always sets `currentEngine
            // = nil` so the `paragraphPlayer` early-return catches it
            // before we reach this switch. Listed here so adding a new
            // engine doesn't bypass the exhaustiveness check.
            break
        case .none:
            break
        }
    }

    /// Resume a paused utterance. SIGCONT for the say subprocess
    /// backend; native continueSpeaking() for AV / NS. The accrued
    /// pause time is folded into `sayTotalPausedDuration` so the
    /// highlight picks up where it left off.
    func resume() async {
        if let player = paragraphPlayer {
            await player.resume()
            return
        }
        if let p = sayProcess, p.isRunning {
            if let pausedAt = sayPauseStartedAt {
                sayTotalPausedDuration += Date().timeIntervalSince(pausedAt)
                sayPauseStartedAt = nil
            }
            kill(p.processIdentifier, SIGCONT)
            return
        }
        switch currentEngine {
        case .avSpeechSynthesizer:
            _ = synthesizer?.continueSpeaking()
        case .nsSpeechSynthesizer:
            nsSynth?.continueSpeaking()
        case .kokoro:
            // Unreachable — see pause() comment. The paragraphPlayer
            // path resumes above before we reach here.
            break
        case .none:
            break
        }
    }

    /// Stop the active utterance immediately. The current `speak(...)`
    /// caller's `try await` returns synchronously from here (we resume
    /// its continuation directly before asking the synth to cancel),
    /// so a stop()→start() race in the coordinator can't let the
    /// prior didCancel resolve the new utterance's continuation. The
    /// late-arriving didCancel sees activeContinuation == nil and is
    /// a harmless no-op. Cancellation remains a successful return per
    /// the documented `speak()` contract.
    ///
    /// For the say subprocess backend, SIGCONT first (in case it's
    /// SIGSTOPed from `pause()`) then SIGTERM via `terminate()` —
    /// without the SIGCONT, SIGTERM would be queued behind the pause
    /// and never deliver.
    func stop() async {
        let prior = activeContinuation
        activeContinuation = nil
        synthesizer?.stopSpeaking(at: .immediate)
        nsSynth?.stopSpeaking()
        if let p = sayProcess, p.isRunning {
            kill(p.processIdentifier, SIGCONT)
            p.terminate()
            sayProcess = nil
            stopSayHighlightSimulation()
        }
        if let player = paragraphPlayer {
            paragraphPlayerTask?.cancel()
            paragraphPlayerTask = nil
            paragraphPlayer = nil
            await player.stop()
        }
        prior?.resume(returning: ())
    }

    // MARK: - Voice ID encoding

    /// Decode `"av:..."`/`"ns:..."` into (engine, identifier). Bare
    /// values (no prefix, no colon) are treated as AV for backward
    /// compatibility with UserDefaults stored before the engine
    /// abstraction shipped. Empty / nil yields the AV default voice.
    nonisolated static func decodeVoiceID(_ raw: String?) -> (engine: SpeechEngine, id: String?) {
        guard let raw, !raw.isEmpty else { return (.avSpeechSynthesizer, nil) }
        if let colon = raw.firstIndex(of: ":") {
            let prefix = String(raw[..<colon])
            let id = String(raw[raw.index(after: colon)...])
            if let engine = SpeechEngine(rawValue: prefix) {
                return (engine, id.isEmpty ? nil : id)
            }
        }
        return (.avSpeechSynthesizer, raw)
    }

    /// Synthesize `text` offline (without playing) and return the audio
    /// as `AudioData`. Uses a *separate* synthesizer instance so an
    /// in-progress live playback isn't interrupted. `AudioExporter`
    /// writes the result to disk. Dispatches by engine prefix on
    /// `voiceID` (`"av:"` / `"ns:"`), or by `useSayCommand` for the
    /// power-user backend.
    func renderToAudioData(text: String, voiceID: String?, rate: Float, pitch: Float, useSayCommand: Bool = false) async throws -> AudioData {
        let (engine, id) = Self.decodeVoiceID(voiceID)

        // Engine prefix wins — same poka-yoke shape as `speak()`. The
        // useSayCommand override is meaningful only for the AV/NS lanes
        // (engines that share the `say` daemon under the hood). New
        // engines must opt in here explicitly.
        if useSayCommand {
            switch engine {
            case .avSpeechSynthesizer, .nsSpeechSynthesizer:
                return try await renderViaSayCommand(text: text, voiceID: id, rate: rate)
            case .kokoro:
                // Kokoro owns its own audio pipeline; the say toggle
                // is a no-op for it. Fall through to the native path.
                break
            }
        }

        switch engine {
        case .avSpeechSynthesizer:
            return try await renderViaAV(text: text, voiceID: id, rate: rate, pitch: pitch)
        case .nsSpeechSynthesizer:
            return try await renderViaNS(text: text, voiceID: id, rate: rate)
        case .kokoro:
            return try await renderViaKokoro(text: text, voiceID: id, rate: rate)
        }
    }

    private func renderViaSayCommand(text: String, voiceID: String?, rate: Float) async throws -> AudioData {
        // Have `say` write an AIFF to a temp file, then load it the
        // same way renderViaNS does.
        let tempURL = try await runSayToAIFF(text: text, voiceID: voiceID, rate: rate)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try loadAudioData(fromAIFFAt: tempURL)
    }

    /// Render `text` to a temporary AIFF file via `/usr/bin/say -o` and
    /// return the file URL. The caller owns the file's lifecycle —
    /// either pass it to AVAudioPlayer for playback (ParagraphPlayer
    /// path) or hand it to `loadAudioData(fromAIFFAt:)` and delete it
    /// (Save Speech As… path). Shared between `renderViaSayCommand`
    /// and the v1.2.1 `SayRenderEngine` so the subprocess plumbing has
    /// one home.
    func runSayToAIFF(text: String, voiceID: String?, rate: Float) async throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talking-say-render-\(UUID().uuidString).aiff")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = ["-o", tempURL.path]
        if let id = voiceID, !id.isEmpty {
            args.append("-v")
            args.append(id)
        }
        let wpm = Int((100 + rate * 300).rounded())
        args.append("-r")
        args.append(String(wpm))
        proc.arguments = args

        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: SpeakError.bufferTypeMismatch)
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
        }
        return tempURL
    }

    /// Load an on-disk AIFF (or other AVAudioFile-supported format)
    /// into the PCM `AudioData` shape `AudioExporter` consumes. The
    /// non-private surface lets `ParagraphPlayer` re-load a paragraph
    /// for re-render scenarios; the live playback path streams the
    /// file directly through AVAudioPlayer and bypasses this.
    func loadAudioData(fromAIFFAt url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { throw SpeakError.bufferTypeMismatch }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw SpeakError.bufferTypeMismatch
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        return AudioData(samples: samples, sampleRate: Int(sourceFormat.sampleRate))
    }

    private func renderViaAV(text: String, voiceID: String?, rate: Float, pitch: Float) async throws -> AudioData {
        let utterance = makeUtterance(text: text, voiceID: voiceID, rate: rate, pitch: pitch)
        let offlineSynth = AVSpeechSynthesizer()

        // Collected samples + the synth's chosen sample rate. The
        // synth picks the rate based on the voice (typically 22 050 Hz
        // for system voices); we honour whatever it gives us.
        var collected: [Float] = []
        var collectedSampleRate: Int = 22050

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AudioData, Error>) in
            // `write(_:toBufferCallback:)` calls back per buffer; an
            // empty `frameLength` signals end-of-stream. Resume the
            // continuation exactly once.
            var didResume = false
            offlineSynth.write(utterance) { buffer in
                guard !didResume else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    didResume = true
                    cont.resume(throwing: SpeakError.bufferTypeMismatch)
                    return
                }
                if pcm.frameLength == 0 {
                    didResume = true
                    cont.resume(returning: AudioData(samples: collected, sampleRate: collectedSampleRate))
                    return
                }
                collectedSampleRate = Int(pcm.format.sampleRate)
                if let channelData = pcm.floatChannelData?[0] {
                    let appended = Array(UnsafeBufferPointer(start: channelData, count: Int(pcm.frameLength)))
                    collected.append(contentsOf: appended)
                }
            }
        }
    }

    private func renderViaNS(text: String, voiceID: String?, rate: Float) async throws -> AudioData {
        // NSSpeechSynthesizer has no buffer callback — it writes a
        // complete AIFF file. Render to a temp URL, await its
        // didFinish, then load the AIFF via AVAudioFile into AudioData.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talking-render-\(UUID().uuidString).aiff")

        let s = NSSpeechSynthesizer()
        if let voiceID, !voiceID.isEmpty {
            _ = s.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceID))
        }
        s.rate = 100 + rate * 300

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let renderDelegate = NSRenderDelegate { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
            s.delegate = renderDelegate
            // Hold a strong reference so the delegate survives the
            // continuation suspension. We capture it inside the
            // delegate's done-closure by tag — the closure pins it.
            renderDelegate.retainAnchor = s
            guard s.startSpeaking(text, to: tempURL) else {
                s.delegate = nil
                cont.resume(throwing: SpeakError.bufferTypeMismatch)
                return
            }
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Load the rendered AIFF as mono Float32 AudioData. NS
        // writes 22 050 Hz mono AIFF on macOS; we honour whatever
        // the file actually declares.
        let file = try AVAudioFile(forReading: tempURL)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { throw SpeakError.bufferTypeMismatch }
        try file.read(into: buffer)
        // If the file is multi-channel, collapse to channel 0 (the NS
        // synth is mono in practice; this is defensive).
        guard let channelData = buffer.floatChannelData?[0] else {
            throw SpeakError.bufferTypeMismatch
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        return AudioData(samples: samples, sampleRate: Int(sourceFormat.sampleRate))
    }

    // MARK: - Internals

    private func makeUtterance(text: String, voiceID: String?, rate: Float, pitch: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            // Fallback: AVSpeechSynthesis picks a voice for the system
            // language. Mirrors TranscriptionService.loadModel's
            // fallback-to-base shape.
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                             min(AVSpeechUtteranceMaximumSpeechRate, rate))
        utterance.pitchMultiplier = max(0.5, min(2.0, pitch))
        return utterance
    }

    private func installDelegate(on synth: AVSpeechSynthesizer, utteranceLength: Int, utteranceID: UInt64) -> Delegate {
        let del = Delegate(
            utteranceID: utteranceID,
            progressContinuation: progressContinuation,
            rangeContinuation: rangeContinuation,
            utteranceLength: utteranceLength,
            onComplete: { [weak self] in
                Task { await self?.resolveActiveContinuation() }
            }
        )
        synth.delegate = del
        return del
    }

    fileprivate func resolveActiveContinuation() {
        activeContinuation?.resume(returning: ())
        activeContinuation = nil
    }

    // MARK: - Delegate

    /// Bridges `AVSpeechSynthesizerDelegate` callbacks into the stream
    /// continuations directly (so order is preserved per the synth's
    /// own serial delivery queue) and resolves the active continuation
    /// via the `onComplete` closure when an utterance ends/cancels.
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        let utteranceID: UInt64
        let progressContinuation: AsyncStream<(UInt64, Double)>.Continuation
        let rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation
        let utteranceLength: Int
        let onComplete: () -> Void

        init(
            utteranceID: UInt64,
            progressContinuation: AsyncStream<(UInt64, Double)>.Continuation,
            rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation,
            utteranceLength: Int,
            onComplete: @escaping () -> Void
        ) {
            self.utteranceID = utteranceID
            self.progressContinuation = progressContinuation
            self.rangeContinuation = rangeContinuation
            self.utteranceLength = utteranceLength
            self.onComplete = onComplete
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            progressContinuation.yield((utteranceID, 0.0))
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            rangeContinuation.yield((utteranceID, characterRange))
            guard utteranceLength > 0 else { return }
            let position = Double(characterRange.location + characterRange.length)
            let progress = min(max(position / Double(utteranceLength), 0.0), 1.0)
            progressContinuation.yield((utteranceID, progress))
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            progressContinuation.yield((utteranceID, 1.0))
            onComplete()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onComplete()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
            // Intentional no-op — the caller drives pause state via
            // AppState; the synth's pause/resume is purely playback.
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
            // See `didPause` above.
        }
    }

    // MARK: - NSSpeechSynthesizer Delegate

    /// Bridge for `NSSpeechSynthesizerDelegate` callbacks.
    /// `willSpeakWord` is the equivalent of AV's
    /// `willSpeakRangeOfSpeechString`. `didFinishSpeaking` covers both
    /// natural completion and explicit `stopSpeaking()` (the BOOL
    /// argument tells us which, but we treat both the same way —
    /// cancellation is a successful return for the caller).
    private final class NSSpeakDelegate: NSObject, NSSpeechSynthesizerDelegate {
        let utteranceID: UInt64
        let progressContinuation: AsyncStream<(UInt64, Double)>.Continuation
        let rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation
        let utteranceLength: Int
        let onComplete: () -> Void

        init(
            utteranceID: UInt64,
            progressContinuation: AsyncStream<(UInt64, Double)>.Continuation,
            rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation,
            utteranceLength: Int,
            onComplete: @escaping () -> Void
        ) {
            self.utteranceID = utteranceID
            self.progressContinuation = progressContinuation
            self.rangeContinuation = rangeContinuation
            self.utteranceLength = utteranceLength
            self.onComplete = onComplete
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               willSpeakWord characterRange: NSRange,
                               of string: String) {
            rangeContinuation.yield((utteranceID, characterRange))
            guard utteranceLength > 0 else { return }
            let position = Double(characterRange.location + characterRange.length)
            let progress = min(max(position / Double(utteranceLength), 0.0), 1.0)
            progressContinuation.yield((utteranceID, progress))
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               didFinishSpeaking finishedSpeaking: Bool) {
            progressContinuation.yield((utteranceID, 1.0))
            onComplete()
        }
    }

    /// Render-only delegate for `renderViaNS` — surfaces NS's
    /// `didFinishSpeaking` as a continuation resume. The `retainAnchor`
    /// pins the synthesizer alive across the await suspension so it
    /// isn't deallocated mid-render.
    private final class NSRenderDelegate: NSObject, NSSpeechSynthesizerDelegate {
        let onDone: (Error?) -> Void
        var retainAnchor: NSSpeechSynthesizer?

        init(onDone: @escaping (Error?) -> Void) {
            self.onDone = onDone
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               didFinishSpeaking finishedSpeaking: Bool) {
            retainAnchor = nil
            onDone(nil)
        }
    }
}

// MARK: - Errors
enum SpeakError: LocalizedError {
    case bufferTypeMismatch
    case voiceUnavailable(String)
    case kokoroUnavailable

    var errorDescription: String? {
        switch self {
        case .bufferTypeMismatch:
            return "Speech synthesizer returned an unexpected buffer type during offline render"
        case .voiceUnavailable(let id):
            return "Voice '\(id)' is not installed on this Mac"
        case .kokoroUnavailable:
            return "Kokoro service is not configured. This is a build-time wiring bug; please report it."
        }
    }
}
