import Foundation
import FluidAudio
import AVFoundation

/// Wraps fluidaudio's `KokoroAneManager` for the v1.3 TTS lane.
///
/// Single actor instance owned by `AppState`. The underlying
/// `KokoroAneManager` is lazy — first call to `synthesize` triggers
/// the HuggingFace model download into
/// `~/Library/Application Support/Talking/kokoro/` (mirrors the
/// `WhisperKit` lazy-load pattern). Subsequent calls reuse the loaded
/// CoreML models.
///
/// Path-A v1.3: returns `RenderedParagraph` with `phonemeTimings:
/// nil`, so `ParagraphPlayer` falls back to its existing
/// `AVAudioPlayer.currentTime` + word-uniformity interpolator.
/// `tokenDurationFrames: [Int32]` from the patched fork is computed
/// and discarded; v1.4 will use it for phoneme-accurate highlights
/// once we expose `G2PModel` and per-word boundary tracking too.
actor KokoroService {

    // MARK: - Voice catalog

    /// FluidInference's `kokoro-82m-coreml/ANE/` directory currently
    /// ships exactly one voice pack: `af_heart.bin`. The other 53
    /// Kokoro voices exist in the same repo as non-ANE `.json` blobs
    /// (`voices/af_bella.json`, …), but fluidaudio's `KokoroAneManager`
    /// only reads `<voice>.bin` from `ANE/`. Picking Emma / Bella /
    /// Michael / George 404s on download.
    ///
    /// Until upstream publishes more `.bin` packs (or we switch to a
    /// port that supports the `.json` format directly), keep the
    /// curated list at one entry. Bella / Michael / Emma / George
    /// are tracked as backlog for the post-v1.3 expansion.
    static let curatedVoices: [KokoroVoice] = [
        KokoroVoice(id: "af_heart", displayName: "Heart", accent: "American English", gender: "Female"),
    ]

    static let defaultVoiceID = "af_heart"

    // MARK: - State

    enum State: Equatable {
        case idle
        case downloading
        case ready
        case error(String)
    }

    private(set) var state: State = .idle {
        didSet { stateContinuation.yield(state) }
    }

    /// State changes broadcast as they happen. AppState subscribes
    /// to mirror this onto a `@Published` field for SwiftUI.
    nonisolated let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    /// Lazy-built manager. `nil` until the first `synthesize` call
    /// resolves the HF download + model load.
    private var manager: KokoroAneManager?

    init() {
        var c: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { c = $0 }
        self.stateContinuation = c
    }

    // MARK: - Public surface

    /// Returns the curated voice list. Synchronous because the catalog
    /// is hard-coded; the manager doesn't need to be loaded.
    nonisolated func availableVoices() -> [KokoroVoice] {
        Self.curatedVoices
    }

    /// Synthesize `text` with `voiceID`, render to a temp WAV file, and
    /// return a `RenderedParagraph` suitable for `ParagraphPlayer`.
    ///
    /// First call triggers the HF download (state transitions: .idle
    /// → .downloading → .ready). Subsequent calls reuse the loaded
    /// manager.
    ///
    /// `rate` is the v1.2.0 normalized 0...1 slider value; Kokoro's
    /// `speed` argument is roughly 1.0 = normal, < 1 slower, > 1
    /// faster. Map `speed = 0.5 + rate` so the 0.5 default rate lands
    /// at 1.0× (normal). 0.0 → 0.5× (slow), 1.0 → 1.5× (brisk). The
    /// earlier `0.5 + rate * 1.5` map sent the default to 1.25×, which
    /// made Kokoro audio sound rushed / cut off.
    ///
    /// **Sentence-by-sentence synthesis.** fluidaudio's `phonemize`
    /// strips all punctuation per word before joining IPAs with spaces,
    /// which erases sentence boundaries and produces unnatural prosody
    /// ("words cut off / weird") on multi-sentence paragraphs. Split
    /// the paragraph on sentence boundaries, synthesize each sentence
    /// independently, and concatenate samples with a short silence gap
    /// so the model gets the natural pauses it expects.
    func synthesize(text: String, voiceID: String?, rate: Float) async throws -> RenderedParagraph {
        let manager = try await loadedManager()
        let voice = voiceID ?? Self.defaultVoiceID
        let speed = Float(0.5 + Double(rate))

        let sentences = Self.splitIntoSentences(text)
        guard !sentences.isEmpty else {
            throw KokoroServiceError.emptyInput
        }

        var combined: [Float] = []
        var sampleRate: Int = 24_000
        let silenceSeconds: Double = 0.12

        for (index, sentence) in sentences.enumerated() {
            let result = try await manager.synthesizeDetailed(
                text: sentence,
                voice: voice,
                speed: speed
            )
            sampleRate = result.sampleRate
            combined.append(contentsOf: result.samples)
            if index < sentences.count - 1 {
                let silenceSampleCount = Int(silenceSeconds * Double(result.sampleRate))
                combined.append(contentsOf: Array(repeating: Float(0), count: silenceSampleCount))
            }
        }

        // Roll our own WAV writer instead of `AudioWAV.data` — that
        // helper peak-normalizes per call (`samples / maxVal`), which
        // boosts gain inconsistently across paragraphs and was the
        // source of the audible ringing / distortion on the smoke
        // test. Kokoro output is already in a clean -1...1 range, so
        // just clamp + convert to Int16 PCM.
        let wavBytes = Self.writeWAV(samples: combined, sampleRate: sampleRate)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talking-kokoro-\(UUID().uuidString).wav")
        try wavBytes.write(to: url)
        let duration = Double(combined.count) / Double(sampleRate)

        return RenderedParagraph(
            audioFileURL: url,
            duration: duration,
            phonemeTimings: nil
        )
    }

    // MARK: - Lazy manager

    private func loadedManager() async throws -> KokoroAneManager {
        if let manager = manager, state == .ready {
            return manager
        }

        state = .downloading
        let manager = KokoroAneManager(
            variant: .english,
            defaultVoice: Self.defaultVoiceID,
            directory: cacheDirectory(),
            computeUnits: .default
        )
        do {
            try await manager.initialize(preloadVoices: nil)
            self.manager = manager
            state = .ready
            return manager
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    private nonisolated func cacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Talking/kokoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Sentence split

    private static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        (trimmed as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (trimmed as NSString).length),
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            guard let substring = substring else { return }
            let cleaned = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                sentences.append(cleaned)
            }
        }

        // `.bySentences` falls back to whole-string for input without
        // sentence terminators (e.g. one terse fragment). That's fine —
        // a single chunk is exactly what we'd want anyway.
        return sentences.isEmpty ? [trimmed] : sentences
    }

    // MARK: - WAV writer (no normalization)

    /// Direct Float32 → 16-bit PCM mono WAV. Mirrors `AudioWAV.data`'s
    /// header layout but drops the peak-normalization step that was
    /// boosting Kokoro output inconsistently and creating perceived
    /// ringing on the smoke test.
    private static func writeWAV(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data()
        pcm.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for s in samples {
            let clipped = max(-1.0, min(1.0, s))
            let v = Int16(clipped * 32767)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        wav.append(contentsOf: "RIFF".data(using: .ascii)!)
        var fileSize = UInt32(36 + pcm.count).littleEndian
        withUnsafeBytes(of: &fileSize) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".data(using: .ascii)!)

        wav.append(contentsOf: "fmt ".data(using: .ascii)!)
        var subchunk1Size = UInt32(16).littleEndian
        withUnsafeBytes(of: &subchunk1Size) { wav.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFormat) { wav.append(contentsOf: $0) }
        var numChannels = UInt16(1).littleEndian
        withUnsafeBytes(of: &numChannels) { wav.append(contentsOf: $0) }
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { wav.append(contentsOf: $0) }
        var byteRate = UInt32(sampleRate * 2).littleEndian
        withUnsafeBytes(of: &byteRate) { wav.append(contentsOf: $0) }
        var blockAlign = UInt16(2).littleEndian
        withUnsafeBytes(of: &blockAlign) { wav.append(contentsOf: $0) }
        var bitsPerSample = UInt16(16).littleEndian
        withUnsafeBytes(of: &bitsPerSample) { wav.append(contentsOf: $0) }

        wav.append(contentsOf: "data".data(using: .ascii)!)
        var dataSize = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &dataSize) { wav.append(contentsOf: $0) }
        wav.append(pcm)

        return wav
    }
}

enum KokoroServiceError: LocalizedError {
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Kokoro received empty input after sentence splitting."
        }
    }
}

/// Kokoro voice descriptor surfaced in the Voice tab picker.
struct KokoroVoice: Sendable, Hashable {
    let id: String
    let displayName: String
    let accent: String
    let gender: String
}
