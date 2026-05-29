import Foundation

/// Represents the current state of the speech-synthesis workflow.
/// Mirrors `TranscriptionState`'s shape so the two lanes can be
/// reasoned about (and rendered) symmetrically.
///
/// Per-word highlight updates live in `AppState.readAlongRange` rather
/// than as an associated value here — keeping this enum coarse keeps
/// the status-icon and menu-bar header from redrawing on every word
/// boundary while still letting the read-along view subscribe to the
/// fine-grained range stream.
enum SpeakState: Equatable, CustomStringConvertible {
    case idle
    case preparing
    case speaking(progress: Double)
    /// Associated progress carries the most-recent value from the
    /// preceding `.speaking` so `resumeSpeak` doesn't snap the
    /// progress bar back to 0 while waiting for the next willSpeak
    /// callback to fire.
    case paused(progress: Double)
    case error(String)

    var description: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing..."
        case .speaking(let progress):
            return "Speaking... \(Int(progress * 100))%"
        case .paused(let progress):
            return "Paused at \(Int(progress * 100))%"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .speaking, .paused:
            return true
        default:
            return false
        }
    }

    /// 0...1 progress when the state carries one; otherwise nil.
    var progress: Double? {
        switch self {
        case .speaking(let p), .paused(let p):
            return p
        default:
            return nil
        }
    }

    static func == (lhs: SpeakState, rhs: SpeakState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing):
            return true
        case (.speaking(let a), .speaking(let b)):
            return a == b
        case (.paused(let a), .paused(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
