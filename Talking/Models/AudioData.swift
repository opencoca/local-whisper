import Foundation
import AVFoundation

/// Container for audio samples in mono Float32 format. The capture and
/// file-load paths produce 16 kHz audio (Whisper's required input); the
/// TTS-render path (v1.2.0+) uses whatever rate `AVSpeechSynthesizer`
/// chose for the active voice (typically 22 050 Hz). `AudioExporter`
/// consumes either via the `sampleRate` field.
struct AudioData {
    /// Audio samples as Float32 array (mono).
    let samples: [Float]

    /// Sample rate in Hz. Defaults to 16 000 for the legacy capture/file
    /// paths; TTS-render passes the synth's native rate.
    let sampleRate: Int

    /// Duration in seconds
    var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }

    /// Check if audio is too short to transcribe
    var isTooShort: Bool {
        duration < 0.5
    }

    init(samples: [Float], sampleRate: Int = 16000) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Create from AVAudioPCMBuffer. Carries the buffer's actual sample
    /// rate forward so resamplers downstream don't have to guess.
    init?(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        let frameCount = Int(buffer.frameLength)
        self.samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        self.sampleRate = Int(buffer.format.sampleRate)
    }
}
