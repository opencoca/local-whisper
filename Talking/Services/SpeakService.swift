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
    private var currentEngine: SpeechEngine?
    private var activeContinuation: CheckedContinuation<Void, Error>?

    /// Monotonically-increasing utterance id. The delegate closes over
    /// the id it was installed with and tags every stream yield, so the
    /// coordinator can drop yields from a preempted utterance whose
    /// callbacks arrive after the next one has started.
    private var nextUtteranceID: UInt64 = 0

    private let progressContinuation: AsyncStream<(UInt64, Double)>.Continuation
    nonisolated let progressStream: AsyncStream<(UInt64, Double)>

    private let rangeContinuation: AsyncStream<(UInt64, NSRange)>.Continuation
    nonisolated let rangeStream: AsyncStream<(UInt64, NSRange)>

    init() {
        var pc: AsyncStream<(UInt64, Double)>.Continuation!
        self.progressStream = AsyncStream { pc = $0 }
        self.progressContinuation = pc

        var rc: AsyncStream<(UInt64, NSRange)>.Continuation!
        self.rangeStream = AsyncStream { rc = $0 }
        self.rangeContinuation = rc
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
        return avInfos + nsInfos
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
    func speak(text: String, voiceID: String?, rate: Float, pitch: Float, useSayCommand: Bool = false) async throws {
        if useSayCommand {
            let (_, id) = Self.decodeVoiceID(voiceID)
            try await speakViaSayCommand(text: text, voiceID: id, rate: rate)
            return
        }
        let (engine, id) = Self.decodeVoiceID(voiceID)
        switch engine {
        case .avSpeechSynthesizer:
            try await speakViaAV(text: text, voiceID: id, rate: rate, pitch: pitch)
        case .nsSpeechSynthesizer:
            try await speakViaNS(text: text, voiceID: id, rate: rate)
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
    private func speakViaSayCommand(text: String, voiceID: String?, rate: Float) async throws {
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
        startSayHighlightSimulation(utteranceID: myID, text: text, wpm: wpm)

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

    // MARK: - Say highlight simulator (time-driven, no per-word callback)

    /// Start a Task that ticks every 80 ms and yields a range/progress
    /// pair to the streams, estimating the current word from elapsed
    /// time × the wpm we passed `say`. Pauses correctly: SIGSTOP
    /// suspends both audio and our elapsed counter via
    /// `sayPauseStartedAt`. Cancellation comes from
    /// `stopSayHighlightSimulation` (terminate / preempt) or when the
    /// process termination handler fires.
    private func startSayHighlightSimulation(utteranceID: UInt64, text: String, wpm: Int) {
        saySpeakingStartedAt = Date()
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
        // Floor at 0.5 s so a one-word utterance doesn't divide by ~0.
        let expectedDuration = max(0.5, totalWords / Double(wpm) * 60.0)

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
    }

    /// Pause the active utterance at the next word boundary. No-op if
    /// nothing is playing. For the `say` subprocess backend, this is
    /// SIGSTOP — the kernel suspends the process, audio cuts
    /// immediately at the kernel boundary (not at a word boundary
    /// like the in-process engines). The highlight simulator's
    /// elapsed counter is paused too so the active word doesn't
    /// drift forward while audio is suspended.
    func pause() {
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
        case .none:
            break
        }
    }

    /// Resume a paused utterance. SIGCONT for the say subprocess
    /// backend; native continueSpeaking() for AV / NS. The accrued
    /// pause time is folded into `sayTotalPausedDuration` so the
    /// highlight picks up where it left off.
    func resume() {
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
    func stop() {
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
        if useSayCommand {
            let (_, id) = Self.decodeVoiceID(voiceID)
            return try await renderViaSayCommand(text: text, voiceID: id, rate: rate)
        }
        let (engine, id) = Self.decodeVoiceID(voiceID)
        switch engine {
        case .avSpeechSynthesizer:
            return try await renderViaAV(text: text, voiceID: id, rate: rate, pitch: pitch)
        case .nsSpeechSynthesizer:
            return try await renderViaNS(text: text, voiceID: id, rate: rate)
        }
    }

    private func renderViaSayCommand(text: String, voiceID: String?, rate: Float) async throws -> AudioData {
        // Have `say` write an AIFF to a temp file, then load it the
        // same way renderViaNS does.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talking-say-render-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tempURL) }

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

        let file = try AVAudioFile(forReading: tempURL)
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

    var errorDescription: String? {
        switch self {
        case .bufferTypeMismatch:
            return "Speech synthesizer returned an unexpected buffer type during offline render"
        case .voiceUnavailable(let id):
            return "Voice '\(id)' is not installed on this Mac"
        }
    }
}
