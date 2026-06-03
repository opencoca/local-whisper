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
    /// `paragraphIndex` / `paragraphCount` are populated by
    /// `ParagraphPlayer` (v1.2.1) when the engine routes long input
    /// through the chunker. AV / NS / single-paragraph `say` callers
    /// can omit them; the default `0 / 1` reads naturally as "one
    /// paragraph, currently on it".
    case speaking(progress: Double, paragraphIndex: Int = 0, paragraphCount: Int = 1)
    /// Associated progress carries the most-recent value from the
    /// preceding `.speaking` so `resumeSpeak` doesn't snap the
    /// progress bar back to 0 while waiting for the next willSpeak
    /// callback to fire. Paragraph fields preserved across the
    /// pause so the footer hint doesn't blink mid-pause.
    case paused(progress: Double, paragraphIndex: Int = 0, paragraphCount: Int = 1)
    case error(String)

    var description: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing..."
        case .speaking(let progress, let pi, let pc):
            return pc > 1
                ? "Speaking... \(Int(progress * 100))% (paragraph \(pi + 1)/\(pc))"
                : "Speaking... \(Int(progress * 100))%"
        case .paused(let progress, let pi, let pc):
            return pc > 1
                ? "Paused at \(Int(progress * 100))% (paragraph \(pi + 1)/\(pc))"
                : "Paused at \(Int(progress * 100))%"
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
        case .speaking(let p, _, _), .paused(let p, _, _):
            return p
        default:
            return nil
        }
    }

    /// 0-based paragraph index for the currently playing chunk.
    /// `nil` outside of `.speaking` / `.paused`.
    var paragraphIndex: Int? {
        switch self {
        case .speaking(_, let pi, _), .paused(_, let pi, _):
            return pi
        default:
            return nil
        }
    }

    /// Total paragraph count for the active utterance. `nil` outside
    /// of `.speaking` / `.paused`. Always ≥ 1 when non-nil.
    var paragraphCount: Int? {
        switch self {
        case .speaking(_, _, let pc), .paused(_, _, let pc):
            return pc
        default:
            return nil
        }
    }

    static func == (lhs: SpeakState, rhs: SpeakState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing):
            return true
        case let (.speaking(a, ai, ac), .speaking(b, bi, bc)):
            return a == b && ai == bi && ac == bc
        case let (.paused(a, ai, ac), .paused(b, bi, bc)):
            return a == b && ai == bi && ac == bc
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
