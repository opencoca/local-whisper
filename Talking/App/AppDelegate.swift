import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState { AppState.shared }
    private let hotkeyManager = HotkeyManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// Runs before `applicationDidFinishLaunching` and before any UI is
    /// created — the right hook for single-instance enforcement so we
    /// terminate before adding a duplicate status item.
    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menu bar only app
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupGlobalShortcut()
        setupStateObserver()

        Task {
            await initializeServices()
        }

        print("[AppDelegate] App launched")
    }

    /// If another Talking.app process is already running, activate it
    /// and terminate ourselves. Standard macOS behavior (Safari, Slack).
    /// Skipped silently when bundle ID is nil (raw `swift run` builds),
    /// so dev-time SwiftPM runs are unaffected.
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard let existing = others.first else { return }
        print("[AppDelegate] Another instance is running (pid \(existing.processIdentifier)); focusing it and quitting.")
        existing.activate()
        NSApp.terminate(nil)
    }
    
    private func setupMenuBar() {
        // Create status item with variable length to fit icon + dot
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = createStatusIcon(dotColor: .yellow) // Yellow = loading
            button.action = #selector(togglePopover)
            button.target = self

            // Overlay a transparent drop view so audio files can be dragged
            // onto the menu-bar icon. The view's hitTest returns nil so
            // mouse clicks still reach the button (popover toggle). The
            // state observer auto-opens the popover when `.transcribing`
            // flips on, so we don't manage popover visibility here.
            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { url in
                Task { @MainActor in
                    await AppState.shared.coordinator.transcribeFile(url: url)
                }
            }
            button.addSubview(dropView)
        }

        // Create popover with SwiftUI view.
        //
        // No explicit `contentSize` — we let NSPopover size to the hosting
        // controller's preferred content size, which respects the `frame(width:)`
        // on `MenuBarView` and grows vertically with intrinsic content. A
        // hard-coded height would crop the live-transcription transcript.
        //
        // `.transient` is the right default (click outside to dismiss) but
        // it gets flipped to `.applicationDefined` while live mode is
        // active — see the $isLiveActive sink in setupStateObserver.
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(appState)
        )
        
        print("[AppDelegate] Menu bar setup complete")
        
        // Listen for settings notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: NSNotification.Name("ShowSettings"),
            object: nil
        )

        // Live-mode coordinator asks for the popover to close before it
        // refocuses the target app for Cmd+V — otherwise the paste would
        // land on the popover itself.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClosePopover),
            name: .closeTalkingPopover,
            object: nil
        )

        // v1.2.0: when the speak lane starts and the user has opted into
        // the read-along window, the coordinator posts this to surface
        // the same `largeLiveWindow` LargeLiveTranscriptionView already
        // owns. The view switches its content/footer based on speakState.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenLargeWindow),
            name: .openTalkingLargeWindow,
            object: nil
        )
    }

    @objc private func handleOpenLargeWindow() {
        showLargeLiveWindow()
    }

    @objc private func handleClosePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }
    
    @objc private func handleShowSettings() {
        showSettings()
    }
    
    /// Observe app state changes and update the menu bar icon. Also
    /// auto-opens the popover when a *file* transcription starts so the
    /// user sees the spinner + filename + timer in-progress UI.
    ///
    /// Critically, the hotkey/record path must NOT trigger the popover:
    /// `popover.show(...)` plus `NSApp.activate(...)` would yank focus
    /// from the user's target app, and the synthetic Cmd+V posted by
    /// `TextInjectionService` ~100 ms later would then land on our
    /// popover instead of where the user was typing.
    ///
    /// `AppState.currentFileName` is the path-discriminator: it's set
    /// only on the file path (by `transcribeFile(url:)`) and `nil` on
    /// the hotkey path. Gating on it is the single condition that keeps
    /// both flows correct.
    private func setupStateObserver() {
        // Observe transcription state
        appState.$transcriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusIcon()
                // File transcription: show the popover so the user sees the
                // spinner + filename + timer.
                if state == .transcribing, AppState.shared.currentFileName != nil {
                    self?.showPopoverIfHidden()
                }
                // Live transcription: show the popover so the user sees the
                // streaming text. `isLiveActive` is the discriminator that
                // keeps the hold-mode `.recording` state from triggering
                // the popover (which would break auto-paste).
                if state == .recording, AppState.shared.isLiveActive {
                    self?.showPopoverIfHidden()
                }
            }
            .store(in: &cancellables)

        // Observe model loaded state
        appState.$isModelLoaded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        // While live transcription is active the popover must stay open so
        // the user can see the streaming text. `.transient` would dismiss
        // on focus shifts triggered by the audio engine and SwiftUI button
        // activation — which is exactly why clicking the popover button
        // appeared to "do nothing." `.applicationDefined` keeps the popover
        // open until we explicitly close it via the
        // `.closeTalkingPopover` notification posted by `stopLive`.
        appState.$isLiveActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.popover.behavior = active ? .applicationDefined : .transient
                // Large transcription window lifecycle. Three modes:
                //   - notepad: always open it (it IS the surface); never
                //     auto-hide on stop — Stop preserves, Clear (in-window
                //     button) is the only destroy affordance.
                //   - autoPaste / clipboardOnly: respect the opt-in
                //     `liveLargeWindowEnabled` preference; auto-hide on stop.
                let notepad = AppState.shared.liveMode == .notepad
                if active {
                    if notepad || AppState.shared.liveLargeWindowEnabled {
                        self?.showLargeLiveWindow()
                        // Two surfaces showing the same state is noise.
                        // When the large window opens, dismiss the popover —
                        // the user looks at one place during a live session.
                        if self?.popover.isShown == true {
                            self?.popover.performClose(nil)
                        }
                    }
                } else {
                    if !notepad {
                        self?.hideLargeLiveWindow()
                    }
                }
            }
            .store(in: &cancellables)

        // If the user flips the floating preference while the window is
        // already up, apply it immediately rather than waiting for the
        // next live session.
        appState.$liveLargeWindowFloating
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] floating in
                self?.largeLiveWindow?.level = floating ? .floating : .normal
            }
            .store(in: &cancellables)

        // v1.2.0 speak lane: when the speak state transitions back to
        // .idle (natural finish, Stop button, or stopSpeak() from any
        // path) and live transcription isn't running, hide the read-
        // along window. Without this the window would stay on screen
        // showing the empty "Stopped / Speak now…" live view after
        // every utterance — confusing.
        appState.$speakState
            .receive(on: DispatchQueue.main)
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] active in
                guard !active else { return }
                guard let self else { return }
                // Don't close a window the live lane owns. The live
                // observer above is the only authority for the live
                // path's window lifecycle.
                guard !self.appState.isLiveActive else { return }
                self.hideLargeLiveWindow()
            }
            .store(in: &cancellables)

        // Restart the HotkeyManager whenever accessibility becomes granted.
        //
        // `HotkeyManager.start()` checks `AXIsProcessTrusted()` once and
        // bails silently if the permission isn't there yet. That means a
        // user who grants accessibility AFTER launch (or who rebuilt the
        // app and triggered the Reset & Re-prompt flow) would otherwise
        // have to quit and relaunch to get global shortcuts working again.
        // `start()` is idempotent — a no-op if the event tap is already
        // installed — so it's safe to call on every grant transition.
        // (Same permission is also what enables CGEvent-based auto-paste,
        // so this single hook fixes both symptoms.)
        appState.permissionsService.$accessibilityGranted
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] granted in
                if granted {
                    self?.hotkeyManager.start()
                }
            }
            .store(in: &cancellables)
    }

    /// Open the popover if it's not already showing. Used to surface the
    /// in-progress UI when a transcription kicks off from any entry
    /// point — drag-drop, file picker, or future paths.
    private func showPopoverIfHidden() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
    }
    
    /// Update status bar icon based on current state
    private func updateStatusIcon() {
        let dotColor: NSColor
        
        switch appState.transcriptionState {
        case .recording:
            dotColor = .systemRed
        case .transcribing:
            dotColor = .systemBlue
        case .idle:
            dotColor = appState.isModelLoaded ? .systemGreen : .systemYellow
        case .error:
            dotColor = .systemOrange
        }
        
        statusItem.button?.image = createStatusIcon(dotColor: dotColor)
    }
    
    /// Create a menu bar icon with a microphone emoji and colored status dot
    private func createStatusIcon(dotColor: NSColor) -> NSImage {
        let size = NSSize(width: 28, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw studio microphone emoji
            let emoji = "🎙️"
            let font = NSFont.systemFont(ofSize: 14)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font
            ]
            let emojiSize = emoji.size(withAttributes: attributes)
            let emojiPoint = NSPoint(
                x: 2,
                y: (rect.height - emojiSize.height) / 2
            )
            emoji.draw(at: emojiPoint, withAttributes: attributes)
            
            // Draw colored status dot in bottom-right corner
            let dotSize: CGFloat = 6
            let dotRect = NSRect(
                x: rect.width - dotSize - 2,
                y: 2,
                width: dotSize,
                height: dotSize
            )
            
            dotColor.setFill()
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
            
            // Add subtle border to dot for visibility
            NSColor.black.withAlphaComponent(0.3).setStroke()
            dotPath.lineWidth = 0.5
            dotPath.stroke()
            
            return true
        }
        
        image.isTemplate = false // Don't use template mode so colors show
        return image
    }
    
    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    private var settingsWindow: NSWindow?
    private var largeLiveWindow: NSWindow?

    /// Show (or focus) the large accessibility transcription window. Called
    /// when live mode starts AND the user has opted in via
    /// `liveLargeWindowEnabled`, and from the v1.2.0 speak lane via
    /// `.openTalkingLargeWindow`. The window is created once and
    /// reused — the SwiftUI hosting controller doesn't rebuild.
    ///
    /// `center()` runs only on creation now. The v1.2.0 speak lane
    /// posts `.openTalkingLargeWindow` on *every* startSpeak, so
    /// re-centering on the reuse path would clobber any manual
    /// placement (multi-monitor, off-center docking) on every Speak
    /// click. Multi-screen users put it where they want it once;
    /// subsequent opens keep the position.
    private func showLargeLiveWindow() {
        if let existing = largeLiveWindow {
            existing.level = appState.liveLargeWindowFloating ? .floating : .normal
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LargeLiveTranscriptionView()
            .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Live Transcription"
        window.minSize = NSSize(width: 500, height: 280)
        window.contentViewController = NSHostingController(rootView: view)
        // Explicitly opaque — defeats any vibrancy the menu-bar-app
        // hosting context might otherwise apply, which is exactly what
        // the user flagged as making the popover hard to read.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.level = appState.liveLargeWindowFloating ? .floating : .normal
        window.center()
        window.makeKeyAndOrderFront(nil)

        largeLiveWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the large transcription window when live mode stops. We just
    /// orderOut rather than close — keeps the window object alive so the
    /// user's manual resize/move persists across sessions.
    private func hideLargeLiveWindow() {
        largeLiveWindow?.orderOut(nil)
    }
    
    func showSettings() {
        print("[AppDelegate] showSettings called")
        
        // Close the popover first
        popover.performClose(nil)
        
        if let window = settingsWindow, window.isVisible {
            print("[AppDelegate] Bringing existing settings window to front")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        print("[AppDelegate] Creating new settings window")
        let settingsView = SettingsView()
            .environmentObject(appState)
        
        // Default size to comfortably show all content (model grid, vocabulary list, etc.)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1200),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Talking Settings"
        window.minSize = NSSize(width: 600, height: 500)
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        print("[AppDelegate] Settings window should be visible now")
    }
    
    private func setupGlobalShortcut() {
        // Load saved hotkeys (hold + live + speak)
        hotkeyManager.loadSavedHotkey()
        hotkeyManager.loadSavedLiveHotkey()
        hotkeyManager.loadSavedSpeakHotkey()

        hotkeyManager.onKeyDown = {
            Task { @MainActor in
                await AppState.shared.coordinator.handleHotkeyPressed()
            }
        }

        hotkeyManager.onKeyUp = {
            Task { @MainActor in
                await AppState.shared.coordinator.handleHotkeyReleased()
            }
        }

        // Live hotkey is a toggle — only onKeyDown is wired, by design.
        // The HotkeyManager still tracks liveIsKeyDown internally for
        // autorepeat coalescing and the stuck-key poka-yoke.
        hotkeyManager.onLiveKeyDown = {
            Task { @MainActor in
                await AppState.shared.coordinator.handleLiveHotkey()
            }
        }

        // Speak hotkey (v1.2.0+) — single press resolves selection or
        // clipboard and starts AVSpeechSynthesizer playback. Same
        // toggle shape as the live hotkey: only onKeyDown wired.
        hotkeyManager.onSpeakKeyDown = {
            Task { @MainActor in
                await AppState.shared.coordinator.handleSpeakHotkey()
            }
        }

        // Start after a short delay to allow permissions to be checked
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.hotkeyManager.start()
        }
    }
    
    private func initializeServices() async {
        log("[AppDelegate] initializeServices() called")
        
        // Check permissions first
        await appState.permissionsService.checkAllPermissions()
        log("[AppDelegate] Permissions checked - Mic: \(appState.permissionsService.microphoneGranted), Accessibility: \(appState.permissionsService.accessibilityGranted)")
        
        // Load whisper model in background (use the user's selected model)
        if appState.permissionsService.microphoneGranted {
            log("[AppDelegate] 🚀 Starting model load: \(appState.selectedModel)")
            await appState.transcriptionService.loadModel(modelName: appState.selectedModel)
            // Update model loaded state after loading completes
            appState.isModelLoaded = await appState.transcriptionService.isModelLoaded
            log("[AppDelegate] ✅ Model load complete - isModelLoaded: \(appState.isModelLoaded)")
        } else {
            log("[AppDelegate] ⚠️ Skipping model load - microphone permission not granted")
        }
    }
    
    /// Log to both console and file for debugging
    private func log(_ message: String) {
        print(message)
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Talking.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
    
    /// Re-check permissions whenever the app regains focus — covers the
    /// case where the user granted access in System Settings and then
    /// switched back before the 2 s poll fires.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await appState.permissionsService.checkAllPermissions()
            appState.isModelLoaded = await appState.transcriptionService.isModelLoaded
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
    }
}

/// Transparent overlay on top of the menu-bar status-item button that
/// accepts dragged audio files. `hitTest` returns nil so mouse clicks
/// still reach the underlying button (and toggle the popover).
final class StatusItemDropView: NSView {
    /// Called on a successful drop with the dropped file's URL.
    var onDrop: ((URL) -> Void)?

    /// Conservative allow-list. AVFoundation can decode more, but these
    /// are the common containers Whisper users actually feed in.
    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "aac", "flac", "aiff", "aif", "caf", "ogg", "opus"
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // Pass clicks through to the status-bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return firstAudioURL(in: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstAudioURL(in: sender) else { return false }
        onDrop?(url)
        return true
    }

    /// Pull the first file URL with an audio extension out of the pasteboard.
    private func firstAudioURL(in info: NSDraggingInfo) -> URL? {
        guard let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return items.first { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
    }
}
