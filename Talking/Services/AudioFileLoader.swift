import Foundation
import AVFoundation
import CoreMedia

/// Loads an audio file from disk and converts it to whisper-compatible
/// `AudioData` (16 kHz mono Float32). Used by the file-transcription
/// flow, paralleling `AudioCaptureService` for live recording — both
/// produce the same `AudioData` shape so `TranscriptionService` doesn't
/// care where the samples came from.
///
/// Two decode paths:
/// 1. `AVAudioFile` (fast, handles .wav / .mp3 / .m4a / .aac / .flac /
///    .aiff / .caf / .ogg / .opus).
/// 2. `AVAssetReader` fallback (handles video containers like .mp4 /
///    .mov / .m4v with mixed audio+video tracks — `AVAudioFile` refuses
///    those). Triggered when path 1 throws.
enum AudioFileLoader {
    /// Read the file at `url`, decode it via AVFoundation, and resample
    /// to 16 kHz mono Float32. Throws on unreadable files or empty audio.
    static func load(url: URL) throws -> AudioData {
        do {
            return try loadViaAVAudioFile(url: url)
        } catch {
            // `AVAudioFile` doesn't open video containers (mp4 with a
            // video track, .mov, .m4v) — fall through to the asset-
            // reader path which can pull the audio track out of any
            // container AVFoundation knows how to read.
            return try loadViaAssetReader(url: url)
        }
    }

    // MARK: - Path 1 — AVAudioFile (audio-only containers)

    private static func loadViaAVAudioFile(url: URL) throws -> AudioData {
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

    // MARK: - Path 2 — AVAssetReader (video containers + anything AVFoundation can read)

    /// Pull the audio track out of any container `AVURLAsset` can read.
    /// Asks the reader to deliver samples already in the WhisperKit-
    /// required shape (16 kHz, mono, Float32, non-interleaved), so no
    /// `AVAudioConverter` step is needed downstream.
    ///
    /// Video-only files (no audio track at all) throw `.noAudioTrack`
    /// with a human-readable message; the coordinator's
    /// `transcribeFile` error path surfaces that to the user.
    private static func loadViaAssetReader(url: URL) throws -> AudioData {
        let asset = AVURLAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioFileLoaderError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioFileLoaderError.conversionFailed(error.localizedDescription)
        }

        // Ask the reader to deliver 16 kHz mono Float32 (non-interleaved).
        // `AVAssetReaderTrackOutput` honours these settings via the
        // backing AudioConverter so we get exactly what whisper wants
        // with no post-processing.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw AudioFileLoaderError.unsupportedFormat
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AudioFileLoaderError.conversionFailed(reader.error?.localizedDescription ?? "asset reader refused to start")
        }

        var samples: [Float] = []
        // Pre-reserve roughly: track duration × 16 kHz, capped at 100 MB
        // worth of samples so a corrupt header doesn't blow memory.
        let estimatedSamples = min(Int(CMTimeGetSeconds(asset.duration) * 16000), 100_000_000 / MemoryLayout<Float>.size)
        if estimatedSamples > 0 { samples.reserveCapacity(estimatedSamples) }

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let err = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard err == kCMBlockBufferNoErr, let dataPointer else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            let floatCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw AudioFileLoaderError.conversionFailed(reader.error?.localizedDescription ?? "asset reader failed")
        }
        guard !samples.isEmpty else {
            throw AudioFileLoaderError.emptyAudio
        }
        return AudioData(samples: samples)
    }
}

// MARK: - Errors
enum AudioFileLoaderError: LocalizedError {
    case unsupportedFormat
    case emptyAudio
    case noAudioTrack
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Audio file format is not supported"
        case .emptyAudio:
            return "Audio file contains no audio data"
        case .noAudioTrack:
            return "File has no audio track (video-only)"
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}
