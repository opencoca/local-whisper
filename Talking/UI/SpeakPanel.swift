import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Popover-section view for the v1.2.0 speak lane.
///
/// Five trigger sources collapsed into one UI: typed text via the
/// editor, selection / clipboard / file / URL via the Source picker.
/// While playback is active, the Speak button becomes Stop and a
/// Pause/Resume pair appears. *Save Audio…* runs an offline render and
/// prompts an NSSavePanel.
struct SpeakPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var typedText: String = ""
    @State private var fileURL: URL?
    @State private var urlString: String = ""
    @State private var sourceTab: SourceTab = .typed

    enum SourceTab: String, CaseIterable, Identifiable {
        case selection = "Selection"
        case clipboard = "Clipboard"
        case typed = "Typed"
        case file = "File"
        case url = "URL"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speak")
                .font(.headline)

            Picker("Source", selection: $sourceTab) {
                ForEach(SourceTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            sourceFields

            controls

            if let error = appState.errorMessage, appState.speakState.isActive == false {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Source-specific fields

    @ViewBuilder
    private var sourceFields: some View {
        switch sourceTab {
        case .selection:
            Text("Speak reads the currently-selected text in the focused app. Falls back to the clipboard if nothing is selected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .clipboard:
            Text("Speak reads whatever is on the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .typed:
            TextEditor(text: $typedText)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        case .file:
            HStack {
                Text(fileURL?.lastPathComponent ?? "No file chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Choose…") { chooseFile() }
                    .buttonStyle(.bordered)
            }
        case .url:
            TextField("https://…", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .textContentType(.URL)
                .onSubmit { if canSpeak { speak() } }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if appState.speakState.isActive {
                if case .paused = appState.speakState {
                    Button {
                        Task { await appState.coordinator.resumeSpeak() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        Task { await appState.coordinator.pauseSpeak() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }
                Button(role: .destructive) {
                    Task { await appState.coordinator.stopSpeak() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                // No global `.keyboardShortcut(.return)` here: the
                // URL TextField uses `.onSubmit` for Return, and the
                // typed TextEditor needs Return for newlines.
                Button {
                    speak()
                } label: {
                    Label("Speak", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSpeak)

                Button {
                    saveAudio()
                } label: {
                    Label("Save Audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(!canSpeak)
            }
        }
    }

    // MARK: - Actions

    private var canSpeak: Bool {
        switch sourceTab {
        case .selection, .clipboard:
            return true
        case .typed:
            return !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            return fileURL != nil
        case .url:
            // Allowlist meaningful schemes so things like `foo:` or
            // `javascript:...` don't enable the Speak button.
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "file"].contains(scheme)
        }
    }

    private func currentSource() -> SpeakSource? {
        switch sourceTab {
        case .selection:
            return .selection
        case .clipboard:
            return .clipboard
        case .typed:
            let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .typed(trimmed)
        case .file:
            return fileURL.map { .file($0) }
        case .url:
            return URL(string: urlString).map { .url($0) }
        }
    }

    private func speak() {
        guard let source = currentSource() else { return }
        Task {
            await appState.coordinator.startSpeak(source: source)
        }
    }

    private func saveAudio() {
        guard let source = currentSource() else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "wav") ?? .audio,
        ]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFilename(forSource: source)
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        let format: AudioExportFormat = url.pathExtension.lowercased() == "wav" ? .wav : .m4a
        Task {
            do {
                try await appState.coordinator.exportSpeakAudio(source: source, to: url, format: format)
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func defaultFilename(forSource source: SpeakSource) -> String {
        let prefix: String
        switch source {
        case .selection: prefix = "selection"
        case .clipboard: prefix = "clipboard"
        case .typed(let text): prefix = String(text.prefix(40))
        case .file(let url): prefix = url.deletingPathExtension().lastPathComponent
        case .url(let url): prefix = url.host ?? "url"
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-\(stamp).m4a"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .plainText,
            .rtf,
            .pdf,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "html") ?? .html,
        ]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
        }
    }
}
