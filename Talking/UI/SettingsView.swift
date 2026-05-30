import SwiftUI
import Carbon.HIToolbox
import AVFoundation
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Model", systemImage: "cpu")
                    .tag(0)
                Label("Vocabulary", systemImage: "text.book.closed")
                    .tag(1)
                Label("Shortcuts", systemImage: "keyboard")
                    .tag(2)
                Label("Live Mode", systemImage: "waveform")
                    .tag(3)
                // v1.2.0 speak lane. Tag 6 (not 4) so the existing
                // settingsDeepLink = 4 for Permissions keeps working
                // without a coordinated rewrite of the popover hint.
                Label("Voice", systemImage: "speaker.wave.2")
                    .tag(6)
                Label("Permissions", systemImage: "lock.shield")
                    .tag(4)
                Label("About", systemImage: "info.circle")
                    .tag(5)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150)
        } detail: {
            Group {
                switch selectedTab {
                case 0:
                    ModelSettingsView()
                case 1:
                    VocabularySettingsView()
                case 2:
                    ShortcutSettingsView()
                case 3:
                    LiveModeSettingsView()
                case 4:
                    PermissionsSettingsView()
                case 5:
                    AboutView()
                case 6:
                    VoiceSettingsView()
                default:
                    ModelSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 600, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(appState)
        // Deep-link support: the popover (and any other caller) sets
        // `appState.settingsDeepLink` before opening this window. We consume
        // it on appear (fresh window) AND on change (window already open).
        .onAppear {
            if let tab = appState.settingsDeepLink {
                selectedTab = tab
                appState.settingsDeepLink = nil
            }
        }
        .onChange(of: appState.settingsDeepLink) { tab in
            if let tab {
                selectedTab = tab
                appState.settingsDeepLink = nil
            }
        }
    }
}

// MARK: - Model Settings
struct ModelSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isReloading = false
    @State private var selectedModelIndex = 0
    
    private let models: [(id: String, name: String, size: String, description: String)] = [
        ("openai_whisper-tiny", "Tiny", "~75MB", "Fastest, basic accuracy"),
        ("openai_whisper-base", "Base", "~140MB", "Fast, good for most uses"),
        ("openai_whisper-small", "Small", "~460MB", "Balanced speed & accuracy"),
        ("openai_whisper-medium", "Medium", "~1.5GB", "High accuracy"),
        ("openai_whisper-large-v3", "Large v3", "~3GB", "Best accuracy"),
        ("openai_whisper-large-v3_turbo", "Large v3 Turbo", "~1.6GB", "Fast & accurate")
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper Model")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Choose a model based on your needs. Larger models are more accurate but slower.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                // Current Status
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(appState.isModelLoaded ? Color.green.opacity(0.2) : Color.yellow.opacity(0.2))
                            .frame(width: 40, height: 40)
                        Image(systemName: appState.isModelLoaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(appState.isModelLoaded ? .green : .yellow)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.isModelLoaded ? "Model Ready" : "Loading Model...")
                            .font(.headline)
                        Text(appState.selectedModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if !appState.isModelLoaded && appState.modelLoadProgress > 0 {
                        ProgressView(value: appState.modelLoadProgress)
                            .frame(width: 100)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)
                
                // Model Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Model")
                        .font(.headline)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(models, id: \.id) { model in
                            ModelCard(
                                model: model,
                                isSelected: appState.selectedModel == model.id,
                                isLoading: isReloading && appState.selectedModel == model.id
                            ) {
                                selectModel(model.id)
                            }
                        }
                    }
                }
                
                // Language Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Language")
                        .font(.headline)
                    
                    Picker("", selection: $appState.language) {
                        Text("English").tag("en")
                        Text("Auto-detect").tag("")
                        Divider()
                        Text("Chinese").tag("zh")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                
                // Recording Options
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording Options")
                        .font(.headline)
                    
                    Toggle(isOn: $appState.muteAudioWhileRecording) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mute speakers while recording")
                            Text("Prevents the microphone from picking up audio playing from your speakers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
                }
                
                Spacer()
            }
            .padding(24)
        }
    }
    
    private func selectModel(_ modelId: String) {
        guard modelId != appState.selectedModel || !appState.isModelLoaded else { return }
        
        appState.selectedModel = modelId
        isReloading = true
        
        Task {
            await appState.transcriptionService.unloadModel()
            await MainActor.run {
                appState.isModelLoaded = false
            }
            await appState.transcriptionService.loadModel(modelName: modelId)
            let loaded = await appState.transcriptionService.isModelLoaded
            await MainActor.run {
                appState.isModelLoaded = loaded
                isReloading = false
            }
        }
    }
}

// MARK: - Model Card
struct ModelCard: View {
    let model: (id: String, name: String, size: String, description: String)
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.name)
                        .font(.headline)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                
                Text(model.size)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vocabulary Settings
struct VocabularySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newWord = ""
    @State private var editingIndex: Int?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Vocabulary")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Add words or phrases to improve transcription accuracy for names, technical terms, or domain-specific vocabulary.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                // Add new word
                HStack(spacing: 12) {
                    TextField("Add a word or phrase...", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addWord()
                        }
                    
                    Button(action: addWord) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                
                // Word list
                if appState.customVocabulary.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.book.closed")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No custom words yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Add words that you frequently use or that are often misheard.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(appState.customVocabulary.enumerated()), id: \.offset) { index, word in
                            HStack {
                                Text(word)
                                    .font(.body)
                                
                                Spacer()
                                
                                Button {
                                    removeWord(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
                            if index < appState.customVocabulary.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
                }
                
                // Tips
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tips", systemImage: "lightbulb")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        tipRow("Add proper nouns, names, and brand names")
                        tipRow("Include technical terms or jargon")
                        tipRow("Add words that are often misheard or misspelled")
                        tipRow("Use correct capitalization for names")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                
                Spacer()
            }
            .padding(24)
        }
    }
    
    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
    }
    
    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !appState.customVocabulary.contains(trimmed) else {
            newWord = ""
            return
        }
        
        withAnimation {
            appState.customVocabulary.append(trimmed)
        }
        newWord = ""
    }
    
    private func removeWord(at index: Int) {
        _ = withAnimation {
            appState.customVocabulary.remove(at: index)
        }
    }
}

// MARK: - Shortcut Settings
struct ShortcutSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var currentShortcut = HotkeyManager.shared.shortcutString
    @State private var isRecordingLive = false
    @State private var currentLiveShortcut = HotkeyManager.shared.liveShortcutString
    @State private var isRecordingSpeak = false
    @State private var currentSpeakShortcut = HotkeyManager.shared.speakShortcutString

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Shortcuts")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Three independent triggers — hold to record, tap to toggle live transcription, tap to read the selection (or clipboard) aloud.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Hold shortcut
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording Shortcut (Hold)")
                        .font(.headline)

                    HStack(spacing: 16) {
                        ShortcutRecorderView(
                            isRecording: $isRecording,
                            currentShortcut: $currentShortcut
                        )

                        Spacer()

                        if !isRecording {
                            Button("Change") {
                                isRecording = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)

                    Text("Hold to record, release to transcribe")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Auto-paste into focused app after stop", isOn: $appState.autoPasteOnHold)
                        .toggleStyle(.switch)
                        .padding(.top, 4)
                    Text(appState.autoPasteOnHold
                         ? "Transcript is pasted via Cmd+V wherever you were typing."
                         : "Transcript lands on the clipboard; paste manually with Cmd+V.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Live shortcut
                VStack(alignment: .leading, spacing: 12) {
                    Text("Live Transcription Shortcut (Toggle)")
                        .font(.headline)

                    HStack(spacing: 16) {
                        ShortcutRecorderView(
                            isRecording: $isRecordingLive,
                            currentShortcut: $currentLiveShortcut,
                            onSave: { keyCode, modifiers in
                                HotkeyManager.shared.setLiveHotkey(keyCode: keyCode, modifiers: modifiers)
                                appState.liveHotkeyKeyCode = keyCode
                                appState.liveHotkeyModifiers = modifiers
                            },
                            readBack: { HotkeyManager.shared.liveShortcutString }
                        )

                        Spacer()

                        if !isRecordingLive {
                            Button("Change") {
                                isRecordingLive = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)

                    Text("Tap to start live transcription, tap again to stop. Text streams in the menu-bar popup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Live mode picker lives in the Live Mode tab now —
                    // see [LiveModeSettingsView]. Keeping the section header
                    // here for the shortcut itself, but the workflow
                    // selection (paste / clipboard / notepad) moved to its
                    // canonical home.
                    Text("Mode selection moved to **Live Mode → Mode**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                // Speak shortcut (v1.2.0)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speak Shortcut (Selection → TTS)")
                        .font(.headline)

                    HStack(spacing: 16) {
                        ShortcutRecorderView(
                            isRecording: $isRecordingSpeak,
                            currentShortcut: $currentSpeakShortcut,
                            onSave: { keyCode, modifiers in
                                HotkeyManager.shared.setSpeakHotkey(keyCode: keyCode, modifiers: modifiers)
                                appState.speakHotkeyKeyCode = keyCode
                                appState.speakHotkeyModifiers = modifiers
                            },
                            readBack: { HotkeyManager.shared.speakShortcutString }
                        )

                        Spacer()

                        if !isRecordingSpeak {
                            Button("Change") {
                                isRecordingSpeak = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)

                    Text("Reads the focused app's text selection aloud via the engine picked in **Voice → Voice**. Falls back to the clipboard when nothing is selected. Voice, rate, pitch, and the say-subprocess option all live in the Voice tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Output method — applies to hold mode and the autoPaste
                // live mode (per-char vs paste). Notepad mode keeps text
                // on-screen only, so no injection happens — disable the
                // picker there to remove the affordance for a setting that
                // would silently no-op.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Output method")
                        .font(.headline)
                    Picker("", selection: $appState.outputMethod) {
                        Text("Paste (fast)").tag(AppState.OutputMethod.paste)
                        Text("Type one character at a time (universal)")
                            .tag(AppState.OutputMethod.typeCharacters)
                    }
                    .pickerStyle(.segmented)
                    .disabled(appState.liveMode == .notepad)
                    Text(appState.liveMode == .notepad
                         ? "Notepad live mode keeps text on-screen only — no injection. Output method applies to hold mode and the Auto-paste / Clipboard-only live modes."
                         : (appState.outputMethod == .typeCharacters
                            ? "Each character is posted as a real keystroke (~5 ms/char). Works in password fields, secure terminals, and any app that blocks paste."
                            : "Uses clipboard + Cmd+V. Fast, but some apps (password fields, certain banking/security apps) reject programmatic paste — switch to character mode if your text isn't landing."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Preset shortcuts
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Presets")
                        .font(.headline)
                    
                    // First row - Primary options
                    HStack(spacing: 12) {
                        PresetShortcutButton(
                            label: "🌐 Globe Key",
                            keyCode: 63,  // Globe/Fn key
                            modifiers: [],
                            currentShortcut: $currentShortcut,
                            isRecommended: true
                        )
                        
                        PresetShortcutButton(
                            label: "⌃⇧Space",
                            keyCode: UInt16(kVK_Space),
                            modifiers: [.maskControl, .maskShift],
                            currentShortcut: $currentShortcut
                        )
                    }
                    
                    // Second row
                    HStack(spacing: 12) {
                        PresetShortcutButton(
                            label: "⌥Space",
                            keyCode: UInt16(kVK_Space),
                            modifiers: [.maskAlternate],
                            currentShortcut: $currentShortcut
                        )
                        
                        PresetShortcutButton(
                            label: "Fn+F5",
                            keyCode: UInt16(kVK_F5),
                            modifiers: [],
                            currentShortcut: $currentShortcut
                        )
                    }
                    
                    // Instructions for Globe Key
                    VStack(alignment: .leading, spacing: 8) {
                        Label("To use the 🌐 Globe Key", systemImage: "info.circle")
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text("1. Open System Settings → Keyboard\n2. Set \"Press 🌐 key to\" → \"Do Nothing\"\n3. Select \"🌐 Globe Key\" above")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
                
                // Usage instructions
                VStack(alignment: .leading, spacing: 12) {
                    Text("How to Use")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        InstructionRow(number: 1, text: "Press and hold the shortcut keys")
                        InstructionRow(number: 2, text: "Speak clearly into your microphone")
                        InstructionRow(number: 3, text: "Release the keys to transcribe")
                        InstructionRow(number: 4, text: "Text is automatically pasted")
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
                }
                
                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Live Mode Settings
struct LiveModeSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var folderText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Mode")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Streaming transcription settings. The hotkey lives under Shortcuts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Mode — what happens on Stop. Replaces the old
                // `autoPasteOnLive` toggle; lives here (rather than under
                // Shortcuts) because it's the top-level live-workflow
                // decision and belongs with the other live settings.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mode")
                        .font(.headline)
                    Picker("Live mode", selection: $appState.liveMode) {
                        Text("Auto-paste").tag(AppState.LiveMode.autoPaste)
                        Text("Clipboard only").tag(AppState.LiveMode.clipboardOnly)
                        Text("Notepad").tag(AppState.LiveMode.notepad)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Caption per mode — semantics obvious without
                    // trial-and-error.
                    Text({
                        switch appState.liveMode {
                        case .autoPaste:
                            return "On stop, the app you were in becomes frontmost again and the transcript is pasted via Cmd+V. Each session is its own paste."
                        case .clipboardOnly:
                            return "On stop, the transcript lands on the clipboard only — paste it manually wherever you choose. Each session is its own clipboard write."
                        case .notepad:
                            return "On stop, nothing leaves the app — review the transcript in the large window. Tapping Record again continues with a paragraph break. Use Clear to start fresh."
                        }
                    }())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Voice-activity detection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Responsiveness")
                        .font(.headline)

                    Toggle("Use voice-activity detection (VAD)", isOn: $appState.liveUseVAD)
                        .toggleStyle(.switch)
                    Text("VAD lets WhisperKit skip silent stretches and only transcribe when speech is detected. Recommended on for most dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence threshold")
                            Spacer()
                            Text(String(format: "%.2f", appState.liveSilenceThreshold))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $appState.liveSilenceThreshold, in: 0.0...1.0, step: 0.05)
                            .disabled(!appState.liveUseVAD)
                        Text("Lower = more sensitive (transcribes quieter audio). Higher = stricter silence skipping. Default 0.30.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Stepper(value: $appState.liveRequiredConfirmationSegments, in: 1...5) {
                        HStack {
                            Text("Segments before a transcript is confirmed")
                            Spacer()
                            Text("\(appState.liveRequiredConfirmationSegments)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    Text("Lower = transcript locks in faster but may shift more. Higher = more stable text but a longer in-flight tail. Default 2.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Display styling
                VStack(alignment: .leading, spacing: 12) {
                    Text("Popover display")
                        .font(.headline)

                    Toggle("Dim unconfirmed text in popover", isOn: $appState.showPartialConfirmationStyling)
                        .toggleStyle(.switch)
                    Text("When on, confirmed segments are shown in your primary text color and the still-in-flight tail in a lighter color so you can see what's settled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Large accessibility window
                VStack(alignment: .leading, spacing: 12) {
                    Text("Large transcription window")
                        .font(.headline)

                    // Notepad mode force-opens the large window regardless
                    // of this toggle (it IS the notepad surface). Disable
                    // the toggle in that case so users can't toggle a
                    // setting that has no effect — poka-yoke: remove the
                    // affordance for an action that doesn't happen.
                    Toggle("Open a large window during live transcription",
                           isOn: notepadAwareLargeWindowBinding)
                        .toggleStyle(.switch)
                        .disabled(appState.liveMode == .notepad)
                    Text(appState.liveMode == .notepad
                         ? "Notepad mode always opens the large window — that's its primary surface."
                         : "Opens an opaque, dedicated window with large text — useful for low-vision users, presentations, or just having the transcript front-and-centre instead of in the small popover.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Font / contrast / floating apply whenever the large
                    // window will actually be shown — either the user opted
                    // in, OR notepad mode forces it.
                    let largeWindowActive = appState.liveLargeWindowEnabled || appState.liveMode == .notepad

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Font size")
                            Spacer()
                            Text("\(Int(appState.liveLargeWindowFontSize)) pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $appState.liveLargeWindowFontSize,
                               in: 24.0...96.0,
                               step: 2.0)
                            .disabled(!largeWindowActive)
                    }
                    .padding(.top, 4)

                    Toggle("High-contrast (bold confirmed text)",
                           isOn: $appState.liveLargeWindowHighContrast)
                        .toggleStyle(.switch)
                        .disabled(!largeWindowActive)
                    Text("Confirmed segments render in semibold weight; the still-being-revised tail stays regular. Easier to distinguish settled vs. in-flux text at a glance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Keep window above other apps",
                           isOn: $appState.liveLargeWindowFloating)
                        .toggleStyle(.switch)
                        .disabled(!largeWindowActive)
                    Text("Window floats above other windows so you can dictate while reading from another app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Save to disk
                VStack(alignment: .leading, spacing: 12) {
                    Text("Save transcripts to disk")
                        .font(.headline)

                    Toggle("Write a `.txt` file after each live stop", isOn: $appState.liveWriteTxtSibling)
                        .toggleStyle(.switch)

                    HStack {
                        Text(appState.liveTxtFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose Folder…") {
                            pickFolder()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!appState.liveWriteTxtSibling)
                    }

                    Text("Files are named `live-<timestamp>.txt`. Folder is created automatically if it doesn't exist yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                Spacer()
            }
            .padding(24)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to save live transcripts"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = appState.liveTxtFolder

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.liveTxtFolder = url
    }

    /// Binding that visually pins the toggle to "on" in notepad mode (since
    /// the large window is force-opened by AppDelegate regardless of the
    /// underlying preference). Writes are no-ops in notepad — the Toggle is
    /// also `.disabled(...)` so the user can't trigger one anyway.
    private var notepadAwareLargeWindowBinding: Binding<Bool> {
        Binding(
            get: { appState.liveMode == .notepad ? true : appState.liveLargeWindowEnabled },
            set: { newValue in
                guard appState.liveMode != .notepad else { return }
                appState.liveLargeWindowEnabled = newValue
            }
        )
    }
}

// MARK: - Shortcut Recorder View
struct ShortcutRecorderView: View {
    @Binding var isRecording: Bool
    @Binding var currentShortcut: String
    /// Called when a new shortcut is captured. The default writes to the hold
    /// hotkey; the live tab passes a closure that targets `setLiveHotkey`.
    var onSave: (UInt16, CGEventFlags) -> Void = { keyCode, modifiers in
        HotkeyManager.shared.setHotkey(keyCode: keyCode, modifiers: modifiers)
    }
    /// Resolves the human-readable shortcut after `onSave`. Defaults to the
    /// hold hotkey's `shortcutString`.
    var readBack: () -> String = { HotkeyManager.shared.shortcutString }

    var body: some View {
        ZStack {
            if isRecording {
                ShortcutRecorderField(
                    isRecording: $isRecording,
                    currentShortcut: $currentShortcut,
                    onSave: onSave,
                    readBack: readBack
                )
            } else {
                // Display current shortcut
                HStack(spacing: 4) {
                    ForEach(parseShortcut(currentShortcut), id: \.self) { part in
                        if part == "+" {
                            Text("+")
                                .foregroundStyle(.secondary)
                        } else {
                            KeyCap(part)
                        }
                    }
                }
            }
        }
    }
    
    private func parseShortcut(_ shortcut: String) -> [String] {
        var parts: [String] = []
        var current = shortcut
        
        let modifiers = ["⌃", "⌥", "⇧", "⌘"]
        for mod in modifiers {
            if current.hasPrefix(mod) {
                parts.append(mod)
                parts.append("+")
                current = String(current.dropFirst())
            }
        }
        
        if !current.isEmpty {
            parts.append(current)
        }
        
        // Remove trailing +
        if parts.last == "+" {
            parts.removeLast()
        }
        
        return parts
    }
}

// MARK: - Shortcut Recorder Field (NSView wrapper)
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var currentShortcut: String
    var onSave: (UInt16, CGEventFlags) -> Void
    var readBack: () -> String

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcutRecorded = { keyCode, modifiers in
            onSave(keyCode, modifiers)
            currentShortcut = readBack()
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }
    
    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        if isRecording {
            // Ensure the view becomes first responder and starts monitoring
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                nsView.startMonitoring()
            }
        } else {
            nsView.stopMonitoring()
        }
    }
}

class ShortcutRecorderNSView: NSView {
    var onShortcutRecorded: ((UInt16, CGEventFlags) -> Void)?
    var onCancel: (() -> Void)?
    private var eventMonitor: Any?
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Draw recording indicator
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.fill()
        
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.stroke()
        
        // Draw text
        let text = "Type your shortcut..."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: point, withAttributes: attributes)
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 32)
    }
    
    func startMonitoring() {
        guard eventMonitor == nil else { return }
        
        // Use local event monitor to capture key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Escape to cancel
            if event.keyCode == UInt16(kVK_Escape) {
                self.onCancel?()
                return nil // Consume the event
            }
            
            // Get modifiers
            var modifiers: CGEventFlags = []
            if event.modifierFlags.contains(.control) {
                modifiers.insert(.maskControl)
            }
            if event.modifierFlags.contains(.option) {
                modifiers.insert(.maskAlternate)
            }
            if event.modifierFlags.contains(.shift) {
                modifiers.insert(.maskShift)
            }
            if event.modifierFlags.contains(.command) {
                modifiers.insert(.maskCommand)
            }
            
            // Require at least one modifier (unless it's a function key or Globe key)
            let isFunctionKey = (event.keyCode >= UInt16(kVK_F1) && event.keyCode <= UInt16(kVK_F20))
            let isGlobeKey = (event.keyCode == 63 || event.keyCode == 179)  // Fn or Globe key
            
            if modifiers.isEmpty && !isFunctionKey && !isGlobeKey {
                // Beep to indicate need modifier
                NSSound.beep()
                return nil
            }
            
            self.onShortcutRecorded?(event.keyCode, modifiers)
            return nil // Consume the event
        }
    }
    
    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
    
    override func keyDown(with event: NSEvent) {
        // Handled by event monitor, but keep as fallback
    }
}

// MARK: - Preset Shortcut Button
struct PresetShortcutButton: View {
    let label: String
    let keyCode: UInt16
    let modifiers: CGEventFlags
    @Binding var currentShortcut: String
    var isRecommended: Bool = false
    
    var isSelected: Bool {
        HotkeyManager.shared.keyCode == keyCode &&
        HotkeyManager.shared.modifiers == modifiers
    }
    
    var body: some View {
        Button {
            HotkeyManager.shared.setHotkey(keyCode: keyCode, modifiers: modifiers)
            currentShortcut = HotkeyManager.shared.shortcutString
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                if isRecommended && !isSelected {
                    Text("★")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : (isRecommended ? Color.orange.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
            .foregroundStyle(isSelected ? .white : .primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecommended && !isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct KeyCap: View {
    let key: String
    
    init(_ key: String) {
        self.key = key
    }
    
    var body: some View {
        Text(key)
            .font(.system(.body, design: .rounded, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
    }
}

struct InstructionRow: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Circle())
            
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - Permissions Settings
struct PermissionsSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Talking needs these permissions to work properly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                // Permission rows
                VStack(spacing: 0) {
                    PermissionRow(
                        icon: "mic.fill",
                        iconColor: .red,
                        title: "Microphone",
                        description: "Required to capture your voice for transcription",
                        isGranted: appState.permissionsService.microphoneGranted
                    ) {
                        appState.permissionsService.openMicrophoneSettings()
                    }
                    
                    Divider()
                        .padding(.leading, 56)
                    
                    PermissionRow(
                        icon: "accessibility",
                        iconColor: .blue,
                        title: "Accessibility",
                        description: "Required for global shortcuts and auto-paste",
                        isGranted: appState.permissionsService.accessibilityGranted
                    ) {
                        appState.permissionsService.requestAccessibilityPermission()
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // One escape hatch for both permissions. Why combined:
                //   - Legacy ad-hoc builds left stale TCC state behind. Both
                //     Accessibility and Microphone get the same disease and
                //     the same cure (`tccutil reset` → re-request).
                //   - Sonoma+ removed the user's ability to manually add an
                //     app to the Microphone list — it must come from an
                //     `AVCaptureDevice.requestAccess` call. So a button is
                //     the only way out of the `.denied` trap.
                //   - One button is honest about the symmetry: if you've hit
                //     the rebuild-killed-my-permissions trap once, you've hit
                //     it for both — fix them in one click.
                if !appState.permissionsService.accessibilityGranted
                    || !appState.permissionsService.microphoneGranted {
                    Button {
                        // Reset both TCC rows for this bundle id. Idempotent —
                        // safe to run even if a permission is currently granted
                        // (the polling timer + Combine sink will re-establish
                        // anything still trusted on the kernel side).
                        for service in ["Accessibility", "Microphone"] {
                            let task = Process()
                            task.launchPath = "/usr/bin/tccutil"
                            task.arguments = ["reset", service, "is.sage.talking"]
                            try? task.run()
                            task.waitUntilExit()
                        }
                        // Accessory apps without active UI can have permission
                        // prompts suppressed by macOS. Force-activate before
                        // requesting, so the dialogs surface reliably.
                        NSApp.activate(ignoringOtherApps: true)
                        // Accessibility uses AXIsProcessTrustedWithOptions —
                        // this returns immediately, the system prompt comes
                        // out-of-band.
                        appState.permissionsService.requestAccessibilityPermission()
                        // Microphone uses async AVCaptureDevice.requestAccess.
                        // Give tccutil's state-reset a beat to settle, then
                        // request. The follow-up checkAllPermissions refreshes
                        // the @Published values once both decisions are in.
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            await appState.permissionsService.checkAllPermissions()
                        }
                    } label: {
                        Label("Reset & Re-request Permissions",
                              systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("One-click recovery for both Accessibility and Microphone. Resets cached TCC state and re-surfaces the macOS system prompts. Use after a rebuild on a legacy ad-hoc-signed install, or any time a permission shows red but the system pane has no Talking row.")
                }

                // Refresh button
                Button {
                    Task {
                        await appState.permissionsService.checkAllPermissions()
                    }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
            .padding(24)
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

// MARK: - About View
struct AboutView: View {
    /// Pull version from the bundle's Info.plist so we never drift from
    /// the value `scripts/release.sh` stamps in at build time.
    /// Falls back to "dev" when run via `swift run` (no Info.plist).
    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "dev"
    }

    /// Read from the bundle's `RepoURL` key (stamped in by `scripts/release.sh`
    /// from `git remote get-url origin`). Falls back to a literal for `swift run`
    /// dev runs where there's no Info.plist.
    private var repoURL: URL {
        if let s = Bundle.main.infoDictionary?["RepoURL"] as? String,
           let u = URL(string: s) { return u }
        return URL(string: "https://github.com/opencoca/local-whisper")!
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)

                Image(systemName: "waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }

            // App name and version
            VStack(spacing: 4) {
                Text("Sage.is Talking")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Version \(versionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Description — reflects the current feature set (hold + live + file)
            Text("100% offline voice-to-text for macOS\nHold to record, tap to live-transcribe, drop in a file")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // Privacy badge
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("100% Offline • Your audio never leaves your device")
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.1))
            .cornerRadius(20)

            // Source code link — required by AGPL-3.0 and useful regardless.
            Link(destination: repoURL) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("Source code")
                }
                .font(.caption)
            }

            Spacer()

            // Credits
            VStack(spacing: 4) {
                Text("Built with WhisperKit by Argmax")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("© 2026 Startr LLC · AGPL-3.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Based on LocalWhisper (MIT, 2024)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Voice (v1.2.0)

/// Settings for the v1.2.0 speak lane: voice picker (grouped by
/// quality tier), rate, pitch, default source for the popover Speak
/// button, and the read-along window toggle.
struct VoiceSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var voiceInfos: [SpeakVoiceInfo] = []
    @State private var samplePlaying: Bool = false
    /// Mirrors AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus
    /// raw value so the @State doesn't carry a macOS-14-only type.
    /// 0 = notDetermined, 1 = denied, 2 = unsupported, 3 = authorized.
    @State private var personalVoiceStatus: UInt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Pick the voice Sage.is Talking uses for spoken output. The Siri voices are downloadable in System Settings — Premium tier is what Siri actually uses (the same neural models).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    voicePicker

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Playback")
                            .font(.headline)

                        rateRow
                        pitchRow

                        HStack {
                            Spacer()
                            Button {
                                playSample()
                            } label: {
                                Label(samplePlayLabel, systemImage: "play.fill")
                            }
                            // Gate on global speakState so a sample
                            // can't collide with hotkey- or popover-
                            // initiated playback (which would preempt
                            // each other via SpeakService's stop /
                            // restart path).
                            .disabled(samplePlaying || appState.speakState.isActive)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Default source")
                            .font(.headline)

                        Picker("", selection: $appState.ttsDefaultSource) {
                            ForEach(AppState.DefaultSpeakSource.allCases, id: \.self) { src in
                                Text(label(for: src)).tag(src)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text("What the Speak button in the popover does when you haven't picked a source explicitly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show read-along window when speaking", isOn: $appState.showReadAlongWindow)
                        Text("Opens the large transcription window in read-along mode while playback runs. Font-size, contrast, and floating settings from Live Mode apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use /usr/bin/say subprocess (power user)", isOn: $appState.ttsUseSayCommand)
                        Text("Routes every utterance through Apple's `say` command instead of AVSpeech / NSSpeech in-process. Trade-offs: read-along highlighting is gone (no per-word callback from a subprocess), pause/resume run via SIGSTOP/SIGCONT (kernel-boundary, not word-boundary), and there's a ~50–100 ms cold-start per utterance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if appState.ttsUseSayCommand {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Hit Siri voices that aren't in the picker", systemImage: "sparkles")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("`say` *without* a -v argument uses whatever's set as your **System Voice** — and that setting can point at a Siri voice that doesn't appear in `say -v \"?\"` discovery. To hear Siri herself read your text:\n\n  1. Pick **System default** in the Voice dropdown above.\n  2. Go to System Voice Settings and set your System Voice to a Siri voice.\n  3. Click Speak — `say` runs with no -v and the daemon falls back to the Siri voice.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Open System Voice Settings…") {
                                    openVoiceSettings()
                                }
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                            sayCalibrationPanel
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speak hotkey")
                            .font(.headline)
                        HStack {
                            Text(HotkeyManager.shared.speakShortcutString)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Spacer()
                            Button("Change in Shortcuts…") {
                                // Deep-link the sidebar over to the Shortcuts
                                // tab (tag 2 — see SettingsView's sidebar list).
                                appState.settingsDeepLink = 2
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(24)
            }
        }
        .onAppear {
            refreshVoices()
        }
    }

    // MARK: - Voice picker

    @ViewBuilder
    private var voicePicker: some View {
        let groups = groupedVoiceInfos()
        let hasNeural = groups.contains { $0.tier == .premium || $0.tier == .enhanced }
        let hasSayOnly = groups.contains { $0.tier == .sayOnly }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Voice", selection: $appState.ttsVoiceID) {
                    Text("System default").tag("")
                    ForEach(groups, id: \.label) { group in
                        Section(group.label) {
                            ForEach(group.voices) { v in
                                Text("\(v.name) — \(v.language)").tag(v.encodedID)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button {
                    refreshVoices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-scan installed system voices — click after downloading new voices in System Settings.")
            }

            if !hasNeural {
                noNeuralVoicesHint
            }

            if hasSayOnly {
                Label("Voices from the legacy synth (the same catalog `say` uses) are tagged \"via say\". They play back fine and the read-along highlight still works — but Apple deprecated this framework in macOS 14, so don't expect new voices here over time.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if #available(macOS 14.0, *) {
                personalVoiceRow
            }
        }
    }

    /// Power-user calibration sliders for the say-subprocess
    /// highlight simulator. Shown only when the say toggle is on
    /// (the caller gates this in the body). Two knobs:
    ///
    /// - **Audio start delay** — how long the highlight pins to
    ///   word 0 before advancing. Compensates for the cold-start
    ///   between `proc.run()` and the first audible sample.
    /// - **Speed correction** — multiplier on the requested wpm.
    ///   `say`'s `-r` is a target, not a guarantee; >1 means audio
    ///   is brisker than the spec, <1 means slower.
    ///
    /// Defaults match SpeakService's defaults (0.18 s, 1.15×).
    @ViewBuilder
    private var sayCalibrationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Calibration", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Button("Reset to defaults") {
                    appState.ttsSayColdStartLag = 0.18
                    appState.ttsSaySpeedFactor = 1.15
                }
                .controlSize(.small)
                .disabled(
                    abs(appState.ttsSayColdStartLag - 0.18) < 0.005 &&
                    abs(appState.ttsSaySpeedFactor - 1.15) < 0.005
                )
            }

            // Cold-start delay: 0–2000 ms in 10 ms increments. The
            // upper bound is deliberately generous — on first-launch
            // / cold-cache or under load `say` can take a beat well
            // beyond the typical ~180 ms before audio actually
            // reaches the speaker. Better to give power users the
            // headroom than have them clipped at 500.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Audio start delay")
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $appState.ttsSayColdStartLag, in: 0...2.0, step: 0.01)
                    Text(coldStartLagLabel)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 72, alignment: .trailing)
                }
                Text("Bump higher if the highlight starts moving before you hear audio. Lower if audio is already speaking by the time word 0 lights up. (Range: 0 ms – 2.00 s.)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Speed factor: 0.50×–2.50× in 0.01 increments. Lower end
            // covers novelty voices (Bells, Bubbles, Cellos) that
            // largely ignore -r and produce a near-fixed ~40–80 wpm
            // cadence; upper end covers fast Siri / Premium voices
            // AND the compound effect of an over-set cold-start lag
            // (see caption). Empirical measurements via
            // `say -o file.aiff` + afinfo landed Aaron Enhanced at
            // 1.03–1.14× and Samantha at 1.11–1.27× (rate-dependent),
            // so the raw voice-rate factor should sit well under
            // 1.30 for system voices. Values above 1.6 usually mean
            // the user is also compensating for cold-start
            // over-estimation; the caption tells them so.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed correction")
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $appState.ttsSaySpeedFactor, in: 0.50...2.50, step: 0.01)
                    Text(String(format: "%.2f×", appState.ttsSaySpeedFactor))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                }
                Text("Higher = highlight moves faster (use when audio is ahead of the highlight). Lower = highlight moves slower. (Range: 0.50× – 2.50×.)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if appState.ttsSaySpeedFactor > 1.60 {
                    Label("If you're above ~1.6× and still lagging audio, try **lowering Audio start delay** too. An over-set cold-start pins the highlight at word 0 after audio has already begun — the highlight then has to sprint the rest of the way to catch up. Shorter utterances feel this more.", systemImage: "lightbulb")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Switches the cold-start-lag readout to seconds once it crosses
    /// 1 s so users don't have to scan a four-digit ms value.
    private var coldStartLagLabel: String {
        let v = appState.ttsSayColdStartLag
        if v >= 1.0 {
            return String(format: "%.2f s", v)
        }
        return "\(Int(v * 1000)) ms"
    }

    /// The empty-state actionable hint when only Default voices are
    /// installed. Lists the actual Siri voice names + a deep link to
    /// the System Settings pane that downloads them.
    @ViewBuilder
    private var noNeuralVoicesHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Siri-quality voices installed.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("**Ava**, **Zoe**, **Evan**, and **Samantha (Premium)** are the same neural voices Siri uses. macOS doesn't pre-install them — download from System Settings (200–400 MB each).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open System Voice Settings…") {
                openVoiceSettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Personal Voice (macOS 14+): clone of the user's own voice,
    /// produced after a few hours of training under
    /// System Settings → Accessibility → Personal Voice. Apps must
    /// request authorization before AVSpeechSynthesisVoice surfaces
    /// the user's cloned voices via .voiceTraits.contains(.isPersonalVoice).
    @available(macOS 14.0, *)
    @ViewBuilder
    private var personalVoiceRow: some View {
        let status = AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus(rawValue: personalVoiceStatus) ?? .notDetermined
        switch status {
        case .notDetermined:
            HStack {
                Label("Personal Voice — read text in your own cloned voice", systemImage: "person.wave.2")
                    .font(.caption)
                Spacer()
                Button("Allow access…") { requestPersonalVoiceAccess() }
                    .controlSize(.small)
            }
        case .authorized:
            // Personal voices now appear in the grouped picker above
            // under their own section. No further UI needed here, but
            // we surface a small confirmation so users know it's on.
            Label("Personal Voice access granted.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied:
            Label("Personal Voice access denied. Re-enable in System Settings → Privacy & Security → Personal Voice.", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsupported:
            Label("This Mac doesn't support Personal Voice (Apple Silicon + macOS 14+ required).", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.tertiary)
        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Voice grouping

    /// Ordered groups for the picker. Personal Voice first, then
    /// AV's neural tiers (Premium / Enhanced), then AV's compact
    /// Default tier, then NS-only voices (regional + novelty) under
    /// their own labeled section. Empty groups are dropped.
    private func groupedVoiceInfos() -> [InfoGroup] {
        let personal = voiceInfos.filter { $0.isPersonalVoice }.sorted { $0.name < $1.name }
        let personalIDs = Set(personal.map(\.id))
        let rest = voiceInfos.filter { !personalIDs.contains($0.id) }
        func avFilter(_ q: SpeakVoiceInfo.Quality) -> [SpeakVoiceInfo] {
            rest.filter { $0.engine == .avSpeechSynthesizer && $0.quality == q }
                .sorted { $0.name < $1.name }
        }
        let nsAll = rest.filter { $0.engine == .nsSpeechSynthesizer }
            .sorted { (a, b) -> Bool in
                // Premium/Enhanced first within NS, then everything else.
                if a.quality != b.quality { return a.quality < b.quality }
                return a.name < b.name
            }
        return [
            InfoGroup(label: "Personal Voice (your cloned voice)", tier: .personal, voices: personal),
            InfoGroup(label: "Premium (Siri-quality, neural)", tier: .premium, voices: avFilter(.premium)),
            InfoGroup(label: "Enhanced (neural)", tier: .enhanced, voices: avFilter(.enhanced)),
            InfoGroup(label: "Default (compact)", tier: .default, voices: avFilter(.default)),
            InfoGroup(label: "Extra voices via say (regional + novelty)", tier: .sayOnly, voices: nsAll),
        ].filter { !$0.voices.isEmpty }
    }

    private struct InfoGroup {
        let label: String
        let tier: Tier
        let voices: [SpeakVoiceInfo]

        enum Tier { case personal, premium, enhanced, `default`, sayOnly }
    }

    // MARK: - Voice actions

    private func refreshVoices() {
        Task {
            let merged = await appState.speakService.availableVoiceInfos()
            await MainActor.run { voiceInfos = merged }
        }
        if #available(macOS 14.0, *) {
            personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus.rawValue
        }
    }

    /// Open the System Settings pane that lists downloadable voices.
    /// macOS Sonoma renamed the Spoken Content pane; we try a couple
    /// of URL schemes and fall back to the generic Universal Access
    /// pane so the user is at most one click away from the right place.
    private func openVoiceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.SpokenContent-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.universalaccess?Spoken_Content",
            "x-apple.systempreferences:com.apple.preference.universalaccess",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @available(macOS 14.0, *)
    private func requestPersonalVoiceAccess() {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
            DispatchQueue.main.async {
                personalVoiceStatus = status.rawValue
                refreshVoices()
            }
        }
    }

    // MARK: - Rate & pitch

    private var rateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Rate")
                    .frame(width: 80, alignment: .leading)
                Slider(value: $appState.ttsRate, in: 0...1)
                Text(String(format: "%.2f", appState.ttsRate))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }
            Text("0 = slowest, 1 = fastest. Default is 0.5.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var pitchRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pitch")
                    .frame(width: 80, alignment: .leading)
                Slider(value: $appState.ttsPitch, in: 0.5...2.0)
                Text(String(format: "%.2f", appState.ttsPitch))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }
            Text("0.5 = lower, 2.0 = higher. Default is 1.0.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Default source label

    private func label(for src: AppState.DefaultSpeakSource) -> String {
        switch src {
        case .selectionOrClipboard: return "Selection (fall back to clipboard)"
        case .clipboard: return "Clipboard"
        case .typedInput: return "Typed input"
        }
    }

    /// Label for the Play sample button, reflecting both the local
    /// `samplePlaying` (a sample WE just kicked off) and the global
    /// `speakState` (any other in-flight playback).
    private var samplePlayLabel: String {
        if samplePlaying { return "Playing sample…" }
        if appState.speakState.isActive { return "Speech in progress…" }
        return "Play sample"
    }

    // MARK: - Sample playback

    private func playSample() {
        samplePlaying = true
        Task {
            await appState.coordinator.startSpeak(
                source: .typed("This is a sample of how the voice sounds at the current rate and pitch.")
            )
            samplePlaying = false
        }
    }
}
