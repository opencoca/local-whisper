import Foundation
import AppKit
import PDFKit
import ApplicationServices

/// Resolves a `SpeakSource` into the literal text to speak. Five
/// input shapes, one return type — so the coordinator never branches
/// on source itself and the rest of the speak lane doesn't care
/// whether the input came from a key chord, a typed string, or a URL.
///
/// The AX selection path requires the Accessibility permission the
/// app already requests for the hotkey tap; no new permission surface.
actor TextSourceService {
    /// Resolve `source` to a string. Returns nil when the source
    /// resolves to empty (no selection, empty clipboard, file with no
    /// text) — callers usually fall back to a different source.
    /// Whitespace-only inputs are treated as empty so the synth
    /// doesn't speak silence and immediately go idle.
    func resolve(_ source: SpeakSource) async throws -> String? {
        switch source {
        case .selection:
            return readSelection()
        case .clipboard:
            return readClipboard()
        case .typed(let text):
            return nonEmpty(text)
        case .file(let url):
            return try await readFile(at: url)
        case .url(let url):
            return try await readURL(url)
        }
    }

    /// Convenience: try `.selection` first, fall back to `.clipboard`.
    /// What the Speak hotkey actually does most of the time.
    func resolveSelectionOrClipboard() -> String? {
        if let selected = readSelection() {
            return selected
        }
        return readClipboard()
    }

    /// Return `nil` for empty / whitespace-only input, else the text.
    private func nonEmpty(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - Selection (Accessibility API)

    private func readSelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        ) == .success,
              let appElement = focusedApp as! AXUIElement?
        else { return nil }

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
              let element = focusedElement as! AXUIElement?
        else { return nil }

        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        ) == .success,
              let text = selectedText as? String
        else { return nil }

        return nonEmpty(text)
    }

    // MARK: - Clipboard

    private func readClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        return nonEmpty(text)
    }

    // MARK: - File (txt / md / rtf / pdf)

    private func readFile(at url: URL) async throws -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else {
                throw TextSourceError.cannotReadFile(url.lastPathComponent)
            }
            return doc.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        case "rtf", "rtfd":
            let data = try Data(contentsOf: url)
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
            let attr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return attr.string
        case "html", "htm":
            let data = try Data(contentsOf: url)
            return try await htmlToString(data: data)
        default:
            // Plain text fall-through covers .txt, .md, anything else
            // the user drops in. Try UTF-8 first, fall back to the
            // system's heuristic encoding so legacy files still work.
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            return try String(contentsOf: url)
        }
    }

    // MARK: - URL fetch

    private func readURL(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let host = url.host ?? url.absoluteString
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Wrap raw NSURLError with the host so the popover shows
            // "Couldn't reach example.com: The request timed out."
            // instead of the bare URLSession message.
            throw TextSourceError.fetchFailed(host, error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TextSourceError.httpError(http.statusCode)
        }
        // Heuristic: try HTML strip first; if it produces no useful
        // text, return the raw decoded body so plain-text URLs still
        // work. Article-mode reader is a v1.x candidate.
        if let stripped = try? await htmlToString(data: data), !stripped.isEmpty {
            return stripped
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - HTML → plain text

    /// `NSAttributedString` HTML loading touches WebKit internals that
    /// historically required the main thread on macOS. Hop via
    /// `MainActor.run` which *suspends* the actor (releasing its
    /// cooperative-pool thread) instead of blocking on a semaphore.
    /// The earlier semaphore implementation pinned a cooperative
    /// thread and would deadlock if this actor were ever re-isolated
    /// to the main actor — fixed now.
    private func htmlToString(data: Data) async throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try await MainActor.run {
            let attr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Errors

enum TextSourceError: LocalizedError {
    case cannotReadFile(String)
    case httpError(Int)
    case fetchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotReadFile(let name):
            return "Could not read file: \(name)"
        case .httpError(let code):
            return "URL fetch returned HTTP \(code)"
        case .fetchFailed(let host, let underlying):
            return "Couldn't reach \(host): \(underlying)"
        }
    }
}
