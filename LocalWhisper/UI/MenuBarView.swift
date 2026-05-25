import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            headerSection
            
            Divider()
            
            // Status Section
            statusSection

            // In-progress section — shown while a transcription is running.
            // Spinner + (optional) filename + live mm:ss timer so the user
            // sees the app is actually working, especially on long files.
            if appState.transcriptionState == .transcribing {
                Divider()
                transcribingSection
            }

            // Live transcription — shown while streaming. Distinct from the
            // .transcribing section above because live mode uses .recording
            // (audio is still flowing) for most of its lifetime.
            if appState.isLiveActive {
                Divider()
                liveSection
            }

            // Permissions Section (if needed)
            if !appState.permissionsService.allPermissionsGranted {
                Divider()
                permissionsSection
            }
            
            Divider()
            
            // Last Transcription
            if !appState.lastTranscription.isEmpty {
                lastTranscriptionSection
                Divider()
            }
            
            // Shortcut Info
            shortcutSection
            
            Divider()
            
            // Actions
            actionsSection
        }
        .padding()
        .frame(width: 320)
    }
    
    // MARK: - Header
    private var headerSection: some View {
        HStack {
            Text("🎙️")
                .font(.title2)
            
            Text("LocalWhisper")
                .font(.headline)
            
            Spacer()
            
            statusBadge
        }
    }
    
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(appState.transcriptionState.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch appState.transcriptionState {
        case .idle:
            return appState.isModelLoaded ? .green : .yellow
        case .recording:
            return .red
        case .transcribing:
            return .blue
        case .error:
            return .orange
        }
    }
    
    // MARK: - Status Section
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Model Status
            HStack {
                Image(systemName: appState.isModelLoaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(appState.isModelLoaded ? .green : .orange)
                
                if appState.isModelLoaded {
                    Text("Model loaded: \(appState.selectedModel)")
                        .font(.caption)
                } else if appState.modelLoadProgress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading model...")
                            .font(.caption)
                        ProgressView(value: appState.modelLoadProgress)
                            .progressViewStyle(.linear)
                    }
                } else {
                    Text("Model not loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Error Message
            if let error = appState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
    
    // MARK: - Transcribing Section
    /// Shown only while a transcription is in flight. The spinner is the
    /// "we're still alive" signal; the timer is the "and we're making
    /// progress" signal. SwiftUI's `Text(timerInterval:)` ticks itself,
    /// so we don't manage a `Timer` here.
    private var transcribingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)

                Text("Transcribing…")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let startedAt = appState.transcriptionStartedAt {
                    // mm:ss live counter. countsDown: false makes it tick up.
                    Text(timerInterval: startedAt...Date.distantFuture,
                         pauseTime: nil,
                         countsDown: false,
                         showsHours: false)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if let fileName = appState.currentFileName {
                Text(fileName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Live Transcription Section
    /// Streaming UI: spinner + mm:ss timer + the running transcript text.
    /// The transcript shows confirmed segments in primary color and the
    /// unconfirmed tail in secondary, controlled by
    /// `appState.showPartialConfirmationStyling`.
    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Live transcription…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let startedAt = appState.transcriptionStartedAt {
                    Text(timerInterval: startedAt...Date.distantFuture,
                         pauseTime: nil,
                         countsDown: false,
                         showsHours: false)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // The transcript itself. minHeight gives a comfortable starting
            // size so the popover doesn't look empty when streaming begins;
            // maxHeight lets it grow until very long dictations would push
            // the action buttons offscreen — then the ScrollView takes over.
            ScrollView {
                Text(liveAttributedTranscript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 400)
        }
    }

    /// Build the attributed transcript shown during live streaming.
    /// Confirmed text is primary; the unconfirmed tail is secondary
    /// unless the user has turned off partial-confirmation styling.
    private var liveAttributedTranscript: AttributedString {
        var s = AttributedString(appState.liveTranscriptConfirmed)
        s.foregroundColor = .primary

        if !appState.liveTranscriptUnconfirmed.isEmpty {
            let prefix = appState.liveTranscriptConfirmed.isEmpty ? "" : " "
            var tail = AttributedString(prefix + appState.liveTranscriptUnconfirmed)
            tail.foregroundColor = appState.showPartialConfirmationStyling ? .secondary : .primary
            s.append(tail)
        }
        return s
    }

    // MARK: - Permissions Section
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions Required")
                .font(.caption)
                .fontWeight(.semibold)

            // Both rows route to Settings → Permissions (tab 4) rather than
            // calling the permission service directly. That way all fix logic
            // (Grant, Reset & Re-prompt, Refresh) lives in one place.
            MenuPermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                granted: appState.permissionsService.microphoneGranted,
                action: { openPermissionsSettings() }
            )

            MenuPermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                granted: appState.permissionsService.accessibilityGranted,
                action: { openPermissionsSettings() }
            )
        }
    }

    /// Open the app's own Permissions tab — single source of truth for all
    /// permission fixes (Grant, Reset & Re-prompt, Refresh Status).
    private func openPermissionsSettings() {
        appState.settingsDeepLink = 4  // Permissions tab
        NotificationCenter.default.post(name: NSNotification.Name("ShowSettings"), object: nil)
    }
    
    // MARK: - Last Transcription
    @State private var showCopiedFeedback = false
    
    private var lastTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last Transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if showCopiedFeedback {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }
            
            Button(action: copyTranscriptionToClipboard) {
                Text(appState.lastTranscription)
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Click to copy to clipboard")
            
            Text("Click to copy")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private func copyTranscriptionToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(appState.lastTranscription, forType: .string)
        
        withAnimation {
            showCopiedFeedback = true
        }
        
        // Hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }
    
    // MARK: - Shortcut Section
    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcut")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Text(HotkeyManager.shared.shortcutString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                
                Spacer()
                
                Text("Hold to record")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Actions Section
    private var actionsSection: some View {
        VStack(spacing: 8) {
            // Live transcription toggle. Same coordinator entry as the
            // live hotkey, so keyboard and mouse share one code path.
            Button(action: toggleLive) {
                HStack {
                    Image(systemName: appState.isLiveActive ? "stop.circle.fill" : "waveform")
                    Text(appState.isLiveActive ? "Stop Live Transcription" : "Start Live Transcription")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundColor(appState.isLiveActive ? .red : .accentColor)
            .disabled(!appState.isModelLoaded ||
                      (appState.transcriptionState == .recording && !appState.isLiveActive))
            .help(appState.isModelLoaded
                  ? "Toggle live transcription (\(HotkeyManager.shared.liveShortcutString))"
                  : "Waiting for the model to load…")

            // File transcription — opens NSOpenPanel for audio files.
            // The same code path is hit by drag-drop on the menu-bar icon
            // (wired in AppDelegate), so both UIs share one coordinator entry.
            Button(action: pickFileToTranscribe) {
                HStack {
                    Image(systemName: "waveform.badge.plus")
                    Text("Transcribe File…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(!appState.isModelLoaded || appState.isLiveActive)
            .help(appState.isModelLoaded
                  ? "Pick an audio file (.wav, .mp3, .m4a, .flac, .aiff, .caf)"
                  : "Waiting for the model to load…")

            HStack {
                Button("Settings...") {
                    // Post notification to open settings
                    NotificationCenter.default.post(name: NSNotification.Name("ShowSettings"), object: nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    /// Toggle live transcription via the same entry point as the live hotkey.
    private func toggleLive() {
        Task { @MainActor in
            await appState.coordinator.handleLiveHotkey()
        }
    }

    /// Open an NSOpenPanel filtered to audio files. On confirm, hand the
    /// URL to the coordinator's file-transcription entry point.
    private func pickFileToTranscribe() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file to transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await appState.coordinator.transcribeFile(url: url)
        }
    }
}

// MARK: - Menu Permission Row (simplified version for menu)
struct MenuPermissionRow: View {
    let icon: String
    let title: String
    let granted: Bool
    let action: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
            
            Text(title)
                .font(.caption)
            
            Spacer()
            
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
