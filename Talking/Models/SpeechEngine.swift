import Foundation

/// Which underlying TTS framework drives playback. v1.2.0 ships two:
///
/// - **`avSpeechSynthesizer`** — modern cross-platform AVFoundation API.
///   Sees voices Apple exposes to third-party apps (Premium/Enhanced
///   ≈ Siri-quality, plus Default compact voices).
/// - **`nsSpeechSynthesizer`** — legacy AppKit framework. Same engine
///   the `say` command shells out to. Sees a *superset* including
///   regional voices and novelty voices (Bad News, Good News, Cellos…)
///   that AV deliberately filters out. Marked deprecated by Apple in
///   macOS 14 but still fully functional, and is the only Swift-callable
///   path to the larger voice catalog without bundling a third-party
///   TTS engine.
///
/// Both engines expose word-range callbacks, so read-along highlighting
/// works regardless of which one the user picks.
enum SpeechEngine: String, CaseIterable, Codable {
    case avSpeechSynthesizer = "av"
    case nsSpeechSynthesizer = "ns"

    var displayName: String {
        switch self {
        case .avSpeechSynthesizer: return "AVSpeechSynthesizer"
        case .nsSpeechSynthesizer: return "NSSpeechSynthesizer"
        }
    }
}

/// Metadata about a single TTS voice from either engine. The picker
/// lists these; `encodedID` is what gets stored in
/// `AppState.ttsVoiceID` so the dispatcher can route at speak() time.
struct SpeakVoiceInfo: Hashable, Identifiable {
    let engine: SpeechEngine
    /// Engine-native identifier — e.g. `com.apple.voice.premium.en-US.Ava`
    /// for AV, or the same string used as `NSSpeechSynthesizer.VoiceName`
    /// for NS. Identifiers happen to overlap between engines because
    /// macOS uses one underlying registry; the difference is which API
    /// surfaces which voices.
    let identifier: String
    let name: String
    let language: String
    let quality: Quality
    let isPersonalVoice: Bool

    enum Quality: String, Comparable {
        case `default`
        case enhanced
        case premium

        private var order: Int {
            switch self {
            case .premium: return 0
            case .enhanced: return 1
            case .default: return 2
            }
        }
        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.order < rhs.order }
    }

    var id: String { encodedID }

    /// Storage form: `"av:com.apple.voice.premium.en-US.Ava"` or
    /// `"ns:com.apple.speech.synthesis.voice.BadNews"`. Decoded by
    /// `SpeakService.decodeVoiceID(_:)`.
    var encodedID: String { "\(engine.rawValue):\(identifier)" }
}
