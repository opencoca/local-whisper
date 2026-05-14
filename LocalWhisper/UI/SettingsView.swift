import SwiftUI
import Carbon.HIToolbox

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Shortcuts")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Two independent triggers — hold to record, or tap to start live transcription.")
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

                    Toggle("Auto-paste into target app after stop", isOn: $appState.autoPasteOnLive)
                        .toggleStyle(.switch)
                        .padding(.top, 4)
                    Text(appState.autoPasteOnLive
                         ? "On stop, the app you were in becomes frontmost again and the transcript is pasted via Cmd+V."
                         : "Transcript lands on the clipboard only; activate your target app and paste manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
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
                    Text("Streaming transcription settings. The shortcut and auto-paste live under Shortcuts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

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
                    Text("LocalWhisper needs these permissions to work properly.")
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
                Text("LocalWhisper")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Description
            Text("Local voice-to-text transcription\npowered by WhisperKit")
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
            
            Spacer()
            
            // Credits
            VStack(spacing: 4) {
                Text("Built with WhisperKit by Argmax")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("© 2024 LocalWhisper")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
