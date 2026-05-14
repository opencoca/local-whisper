import Foundation
import WhisperKit

/// Wraps WhisperKit's `AudioStreamTranscriber` so the coordinator doesn't
/// have to deal with its six-arg constructor inline. Owns its own
/// `AudioProcessor` (separate from our existing mic-record service) —
/// streaming and batch recording are mutually exclusive at the
/// coordinator layer, so two audio engines never run simultaneously.
@MainActor
final class LiveTranscriptionService {
    private var streamer: AudioStreamTranscriber?

    /// Latest state, captured from every `stateChangeCallback` tick. Used
    /// by `stop()` to return the final transcript — `AudioStreamTranscriber`
    /// keeps `state` private so we mirror it here.
    private var lastState: AudioStreamTranscriber.State?

    var isStreaming: Bool { streamer != nil }

    /// Start a streaming transcription.
    /// - Parameter onUpdate: called on every state tick with the joined
    ///   confirmed and unconfirmed text. Runs on `@MainActor` so it's safe
    ///   to write directly to `@Published` properties.
    func start(
        whisperKit: WhisperKit,
        language: String,
        prompt: String?,
        useVAD: Bool,
        silenceThreshold: Float,
        requiredSegmentsForConfirmation: Int,
        onUpdate: @escaping (_ confirmed: String, _ unconfirmed: String) -> Void
    ) async throws {
        guard streamer == nil else { return }
        guard let tokenizer = whisperKit.tokenizer else {
            throw LiveTranscriptionError.modelNotReady
        }

        // Match the prompt-token construction used by the batch path in
        // `TranscriptionService.transcribe(_:language:prompt:)`.
        var promptTokens: [Int]? = nil
        if let prompt, !prompt.isEmpty {
            let encoded = tokenizer.encode(text: " " + prompt)
            promptTokens = encoded.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language.isEmpty ? nil : language,
            skipSpecialTokens: true,
            withoutTimestamps: false,  // streaming uses timestamps for segmentation
            promptTokens: promptTokens
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: requiredSegmentsForConfirmation,
            silenceThreshold: silenceThreshold,
            useVAD: useVAD,
            stateChangeCallback: { [weak self] _, newState in
                guard let self else { return }
                Task { @MainActor in
                    self.lastState = newState
                    let confirmed = newState.confirmedSegments
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let unconfirmed = newState.unconfirmedSegments
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    onUpdate(confirmed, unconfirmed)
                }
            }
        )

        self.streamer = transcriber
        self.lastState = nil

        // `startStreamTranscription` runs the realtime loop on its own task
        // and returns when recording stops. We don't await it here, or
        // `start()` wouldn't return until the user pressed stop. Kick it
        // off detached and let the coordinator drive the lifecycle via
        // `stop()`.
        Task.detached(priority: .userInitiated) {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                print("[LiveTranscriptionService] stream task error: \(error)")
            }
        }
    }

    /// Stop the streamer and return the final concatenated transcript.
    /// Returns the empty string if nothing was captured.
    @discardableResult
    func stop() async -> String {
        await streamer?.stopStreamTranscription()
        defer {
            streamer = nil
            lastState = nil
        }
        guard let state = lastState else { return "" }
        let confirmed = state.confirmedSegments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let combined = [confirmed, unconfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LiveTranscriptionError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Whisper model isn't ready for streaming yet"
        }
    }
}
