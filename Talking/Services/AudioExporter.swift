import Foundation
@preconcurrency import AVFoundation

/// Audio container formats supported by `AudioExporter`. Single
/// enumeration so both directions of audio (captured recordings and
/// synthesized speech) speak the same vocabulary at the save panel.
enum AudioExportFormat: String, CaseIterable {
    case wav
    case m4a

    var fileExtension: String { rawValue }

    var contentType: String {
        switch self {
        case .wav: return "com.microsoft.waveform-audio"
        case .m4a: return "com.apple.m4a-audio"
        }
    }

    var displayName: String {
        switch self {
        case .wav: return "WAV (PCM, larger, lossless)"
        case .m4a: return "M4A (AAC, smaller, near-lossless for speech)"
        }
    }
}

/// Writes `AudioData` to disk in `.wav` or `.m4a`. Used by both the
/// *Save Last Recording…* path (captured 16 kHz mono Float32 from
/// `AudioCaptureService`) and the *Save Speech As…* path
/// (synthesized samples from `SpeakService.renderToAudioData`).
///
/// The exporter is the *single* code path in the app that writes audio
/// files — keeping format support in one place means a future addition
/// (FLAC, OGG, …) appears in both menus automatically.
actor AudioExporter {
    /// Write `audio` to `url` in the chosen `format`. Overwrites if
    /// the file already exists. Throws on filesystem or codec errors.
    func exportToFile(audio: AudioData, to url: URL, format: AudioFormat) throws {
        switch format {
        case .wav:
            try writeWAV(audio: audio, to: url)
        case .m4a:
            try writeM4A(audio: audio, to: url)
        }
    }

    /// Suggest a filename based on transcript content: 40 sanitized
    /// chars + ISO-8601 timestamp (seconds precision). No extension —
    /// the save panel adds that based on the format choice.
    func defaultFilename(forTranscript transcript: String, at date: Date) -> String {
        let prefix = sanitize(prefix: transcript, maxLength: 40)
        let stamp = isoTimestamp(date)
        let trimmedPrefix = prefix.isEmpty ? "audio" : prefix
        return "\(trimmedPrefix)-\(stamp)"
    }

    // MARK: - WAV (PCM Float32, source sample rate)

    private func writeWAV(audio: AudioData, to url: URL) throws {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(audio.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioExportError.formatConfiguration
        }

        // `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`
        // chooses the on-disk format from `settings` and converts from
        // `commonFormat` on the way in. For WAV we want the same
        // interpretation throughout (Float32).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(audio.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let buffer = try makeBuffer(from: audio.samples, format: sourceFormat)
        try file.write(from: buffer)
    }

    // MARK: - M4A (AAC, mono, 22 050 Hz)

    private func writeM4A(audio: AudioData, to url: URL) throws {
        // AAC's preferred input for speech is 22 050 Hz mono. Source
        // is at `audio.sampleRate` (16 kHz for capture, 22 050 for
        // most TTS voices). If they already match we skip the
        // resampler; otherwise `AVAudioConverter` does it in one pass.
        let targetSampleRate: Double = 22050

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(audio.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioExportError.formatConfiguration
        }
        guard let resampleTarget = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioExportError.formatConfiguration
        }

        let sourceBuffer = try makeBuffer(from: audio.samples, format: sourceFormat)
        let workingBuffer: AVAudioPCMBuffer
        if Double(audio.sampleRate) == targetSampleRate {
            workingBuffer = sourceBuffer
        } else {
            workingBuffer = try resample(sourceBuffer, from: sourceFormat, to: resampleTarget)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        try file.write(from: workingBuffer)
    }

    // MARK: - Shared helpers

    private func makeBuffer(from samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AudioExportError.formatConfiguration
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioExportError.formatConfiguration
        }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelData.initialize(from: base, count: samples.count)
            }
        }
        return buffer
    }

    private func resample(
        _ source: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioExportError.resamplerUnavailable
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioExportError.formatConfiguration
        }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return source
        }
        if let error {
            throw AudioExportError.conversionFailed(error.localizedDescription)
        }
        guard status != .error else {
            throw AudioExportError.conversionFailed("AVAudioConverter returned .error")
        }
        return out
    }

    private func sanitize(prefix: String, maxLength: Int) -> String {
        let collapsed = prefix
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let filtered = collapsed.replacingOccurrences(
            of: "[^A-Za-z0-9 \\-]",
            with: "",
            options: .regularExpression
        )
        let trimmed = filtered
            .prefix(maxLength)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return trimmed
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Replace ':' so the result is filesystem-safe (Windows shares,
        // sandboxed scoped URLs, etc. all dislike colons in filenames).
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    // Public-API-friendly alias kept on the type to match the plan's
    // wording: the exporter doesn't know what kind of audio it's
    // writing — capture or synthesis — only the format requested.
    typealias AudioFormat = AudioExportFormat
}

// MARK: - Errors

enum AudioExportError: LocalizedError {
    case formatConfiguration
    case resamplerUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .formatConfiguration:
            return "Could not configure the audio format for export"
        case .resamplerUnavailable:
            return "Could not create a resampler for the chosen format"
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}
