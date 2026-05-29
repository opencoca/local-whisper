import Foundation
import AVFoundation

/// Loads an audio file from disk and converts it to whisper-compatible
/// `AudioData` (16 kHz mono Float32). Used by the file-transcription
/// flow, paralleling `AudioCaptureService` for live recording — both
/// produce the same `AudioData` shape so `TranscriptionService` doesn't
/// care where the samples came from.
enum AudioFileLoader {
    /// Read the file at `url`, decode it via AVFoundation, and resample
    /// to 16 kHz mono Float32. Throws on unreadable files or empty audio.
    static func load(url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat

        // Whisper's required input: 16 kHz mono Float32 (matches AudioCaptureService).
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileLoaderError.unsupportedFormat
        }

        // Read the whole file into a single source buffer. In practice
        // hour-plus files transcribe fine (90-min interview proven), and
        // RAM is the actual ceiling — no streaming complexity needed.
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioFileLoaderError.emptyAudio
        }
        try file.read(into: sourceBuffer)

        // Fast path: file is already 16 kHz mono Float32 (rare but possible).
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = sourceBuffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(sourceBuffer.frameLength)))
            return AudioData(samples: samples)
        }

        // Convert. Sample-rate ratio scales the output capacity; +1024 is
        // converter slack so the last packet always fits.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileLoaderError.unsupportedFormat
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw AudioFileLoaderError.unsupportedFormat
        }

        // Single-shot conversion: hand the whole source buffer over once,
        // then signal end-of-stream so the converter flushes its tail.
        var didProvide = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
            if didProvide {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let convertError = convertError {
            throw AudioFileLoaderError.conversionFailed(convertError.localizedDescription)
        }
        guard status != .error,
              let channelData = outBuffer.floatChannelData?[0],
              outBuffer.frameLength > 0 else {
            throw AudioFileLoaderError.emptyAudio
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outBuffer.frameLength)))
        return AudioData(samples: samples)
    }
}

// MARK: - Errors
enum AudioFileLoaderError: LocalizedError {
    case unsupportedFormat
    case emptyAudio
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Audio file format is not supported"
        case .emptyAudio:
            return "Audio file contains no audio data"
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}
