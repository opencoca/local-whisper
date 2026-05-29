import Foundation

/// Tags *where the text to speak came from* so the coordinator can
/// log it, restore it as the "last spoken" item, and route the right
/// resolver in `TextSourceService` (e.g. AX selection for `.selection`,
/// `URLSession` fetch for `.url`, `String(contentsOf:)` for `.file`).
///
/// `.typed` carries the literal text the user typed; the other cases
/// carry the address from which the text is fetched.
enum SpeakSource: Equatable, CustomStringConvertible {
    case selection
    case clipboard
    case typed(String)
    case file(URL)
    case url(URL)

    var description: String {
        switch self {
        case .selection:
            return "Selection"
        case .clipboard:
            return "Clipboard"
        case .typed:
            return "Typed text"
        case .file(let url):
            return "File: \(url.lastPathComponent)"
        case .url(let url):
            return "URL: \(url.host ?? url.absoluteString)"
        }
    }
}
