import Foundation
@preconcurrency import AVFoundation

/// Wraps `AVSpeechSynthesizer` for the speak lane. Mirrors
/// `TranscriptionService`'s actor + progress-stream shape so the two
/// lanes can be reasoned about symmetrically.
///
/// Streams:
/// - `progressStream` — overall progress 0...1, coarse (per-word).
/// - `rangeStream` — character range of the *currently spoken* word
///   inside the active utterance. Drives the read-along highlight.
///
/// Playback API is one-utterance-at-a-time: calling `speak(...)` while
/// another utterance is in flight cancels the previous one (`stop` →
/// `didCancel` resolves the prior continuation) and starts the new one.
actor SpeakService {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: Delegate?
    private var activeContinuation: CheckedContinuation<Void, Error>?

    private let progressContinuation: AsyncStream<Double>.Continuation
    nonisolated let progressStream: AsyncStream<Double>

    private let rangeContinuation: AsyncStream<NSRange>.Continuation
    nonisolated let rangeStream: AsyncStream<NSRange>

    init() {
        var pc: AsyncStream<Double>.Continuation!
        self.progressStream = AsyncStream { pc = $0 }
        self.progressContinuation = pc

        var rc: AsyncStream<NSRange>.Continuation!
        self.rangeStream = AsyncStream { rc = $0 }
        self.rangeContinuation = rc
    }

    /// Returns the installed system voices. Caller groups by
    /// `AVSpeechSynthesisVoice.quality` (default / enhanced / premium)
    /// for the picker UI. Premium / Enhanced voices appear only after
    /// the user installs them via *System Settings → Accessibility →
    /// Spoken Content → Manage Voices*.
    func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    /// Start playback. Returns when the synthesizer reports `didFinish`
    /// or `didCancel` for the *passed* utterance — i.e. the call awaits
    /// until either speech completes or another `speak()`/`stop()`
    /// supersedes it. Throws only for upstream configuration errors;
    /// cancellation is a successful return.
    func speak(text: String, voiceID: String?, rate: Float, pitch: Float) async throws {
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

        let utterance = makeUtterance(text: text, voiceID: voiceID, rate: rate, pitch: pitch)
        let synth = synthesizer ?? AVSpeechSynthesizer()
        let del = installDelegate(on: synth, utteranceLength: text.utf16.count)
        delegate = del
        synthesizer = synth

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activeContinuation = cont
            synth.speak(utterance)
        }
    }

    /// Pause the active utterance at the next word boundary. No-op if
    /// nothing is playing.
    func pause() {
        synthesizer?.pauseSpeaking(at: .word)
    }

    /// Resume a paused utterance. No-op if nothing is paused.
    func resume() {
        _ = synthesizer?.continueSpeaking()
    }

    /// Stop the active utterance immediately. The current `speak(...)`
    /// continuation resolves as a successful return (cancellation is not
    /// an error for the caller). Same poka-yoke as `speak`'s preempt:
    /// we resolve + clear the active continuation BEFORE asking the
    /// synth to cancel, so the late-arriving didCancel sees nil and is
    /// a no-op. Otherwise a stop()→start() race would let the prior
    /// didCancel resolve the new utterance's continuation.
    func stop() {
        let prior = activeContinuation
        activeContinuation = nil
        synthesizer?.stopSpeaking(at: .immediate)
        prior?.resume(returning: ())
    }

    /// Synthesize `text` offline (without playing) and return the audio
    /// as `AudioData`. Uses a *separate* synthesizer instance so an
    /// in-progress live playback isn't interrupted. `AudioExporter`
    /// writes the result to disk.
    func renderToAudioData(text: String, voiceID: String?, rate: Float, pitch: Float) async throws -> AudioData {
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

    private func installDelegate(on synth: AVSpeechSynthesizer, utteranceLength: Int) -> Delegate {
        let del = Delegate(
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
        let progressContinuation: AsyncStream<Double>.Continuation
        let rangeContinuation: AsyncStream<NSRange>.Continuation
        let utteranceLength: Int
        let onComplete: () -> Void

        init(
            progressContinuation: AsyncStream<Double>.Continuation,
            rangeContinuation: AsyncStream<NSRange>.Continuation,
            utteranceLength: Int,
            onComplete: @escaping () -> Void
        ) {
            self.progressContinuation = progressContinuation
            self.rangeContinuation = rangeContinuation
            self.utteranceLength = utteranceLength
            self.onComplete = onComplete
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            progressContinuation.yield(0.0)
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            rangeContinuation.yield(characterRange)
            guard utteranceLength > 0 else { return }
            let position = Double(characterRange.location + characterRange.length)
            let progress = min(max(position / Double(utteranceLength), 0.0), 1.0)
            progressContinuation.yield(progress)
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            progressContinuation.yield(1.0)
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
