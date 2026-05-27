import SwiftUI

/// Minimal iOS settings sheet. Three sections:
/// - Model: which Whisper variant is loaded (tiny.en is bundled; base /
///   small / large-v3-turbo are downloadable on demand).
/// - Live: font size slider + high-contrast toggle.
/// - About: version + license link.
struct SettingsView: View {
    @EnvironmentObject var appState: MobileAppState
    @Environment(\.dismiss) private var dismiss

    /// Whisper variants exposed in the UI. tiny.en is the bundled default;
    /// the others require a one-time download and add disk pressure.
    private let availableModels: [(id: String, label: String, sizeNote: String)] = [
        ("openai_whisper-tiny.en", "Tiny (English) — bundled",      "~75 MB"),
        ("openai_whisper-base",    "Base — better accuracy",        "~140 MB"),
        ("openai_whisper-small",   "Small — much better accuracy",  "~470 MB"),
        ("openai_whisper-large-v3-turbo", "Large v3 Turbo — best",  "~1.5 GB")
    ]

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    ForEach(availableModels, id: \.id) { model in
                        Button {
                            appState.selectedModel = model.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.label)
                                        .foregroundColor(.primary)
                                    Text(model.sizeNote)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if appState.selectedModel == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }

                    Text("Larger models are downloaded on first selection and cached on-device. All transcription runs 100% offline.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Live transcription") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Font size")
                            Spacer()
                            Text("\(Int(appState.liveLargeWindowFontSize)) pt")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.liveLargeWindowFontSize, in: 18...96, step: 2)
                    }

                    Toggle("High-contrast text",
                           isOn: $appState.liveLargeWindowHighContrast)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }

                    Link("Source code (GitHub)",
                         destination: URL(string: "https://github.com/opencoca/local-whisper")!)

                    Link("License — AGPL-3.0",
                         destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.en.html")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
