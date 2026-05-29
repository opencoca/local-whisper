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
    case paused
    case error(String)

    var description: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing..."
        case .speaking(let progress):
            return "Speaking... \(Int(progress * 100))%"
        case .paused:
            return "Paused"
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

    static func == (lhs: SpeakState, rhs: SpeakState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.paused, .paused):
            return true
        case (.speaking(let a), .speaking(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
