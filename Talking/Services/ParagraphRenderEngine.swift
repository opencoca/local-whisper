import Foundation
import AVFoundation

/// Per-paragraph audio render contract for `ParagraphPlayer`.
/// v1.2.1 ships `SayRenderEngine`. v1.3 adds `KokoroRenderEngine`
/// alongside it via the same interface.
protocol ParagraphRenderEngine: Sendable {
    func render(paragraph: String, voiceID: String?, rate: Float) async throws -> RenderedParagraph
}

/// Output of one paragraph render. The engine writes audio to a temp
/// file on disk; `ParagraphPlayer` is responsible for deleting the
/// file after playback (or earlier on stop/preempt).
///
/// `duration` is the ground-truth playback length read from the audio
/// file's frame count — this is the key win over the v1.2.0 `say`
/// path: the highlight interpolator anchors to a known duration
/// instead of `totalWords / (wpm * speedFactor) * 60`.
///
/// `phonemeTimings` is non-nil only when the engine's underlying
/// model exposes per-phoneme durations (a v1.3 Kokoro feature gated
/// on the chosen port). When non-nil, `ParagraphPlayer` skips the
/// interpolator and drives highlights directly from these timings.
struct RenderedParagraph: Sendable {
    let audioFileURL: URL
    let duration: TimeInterval
    let phonemeTimings: PhonemeTimings?
}

/// Per-phoneme timing data for engines that expose it. `say` does
/// not; some v1.3 Kokoro CoreML ports do via the model's internal
/// duration predictor.
struct PhonemeTimings: Sendable {
    let phonemes: [Phoneme]

    struct Phoneme: Sendable {
        let text: String
        let startSec: TimeInterval
        let endSec: TimeInterval
    }
}

/// `ParagraphRenderEngine` conformer that renders via
/// `/usr/bin/say -o` to a temp AIFF. Delegates the subprocess
/// plumbing to `SpeakService.runSayToAIFF` so the existing v1.2.0
/// `say` lane (used by Save Speech As…) and this lane share a single
/// rendering codepath.
struct SayRenderEngine: ParagraphRenderEngine {
    let speakService: SpeakService

    func render(paragraph: String, voiceID: String?, rate: Float) async throws -> RenderedParagraph {
        let url = try await speakService.runSayToAIFF(
            text: paragraph,
            voiceID: voiceID,
            rate: rate
        )
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return RenderedParagraph(
            audioFileURL: url,
            duration: duration,
            phonemeTimings: nil
        )
    }
}

/// v1.3 — `ParagraphRenderEngine` conformer that delegates to
/// `KokoroService.synthesize`. The service already handles
/// sentence-level chunking + silence gaps inside each paragraph
/// and writes a temp WAV; this adapter is just plumbing so the
/// `ParagraphPlayer` machinery (pre-render, AVAudioPlayer playback,
/// highlight interpolation, pause/resume, stop) is shared with the
/// chunked-say lane.
struct KokoroRenderEngine: ParagraphRenderEngine {
    let service: KokoroService

    func render(paragraph: String, voiceID: String?, rate: Float) async throws -> RenderedParagraph {
        try await service.synthesize(text: paragraph, voiceID: voiceID, rate: rate)
    }
}
