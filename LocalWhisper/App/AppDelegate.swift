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
    
    private func setupMenuBar() {
        // Create status item with variable length to fit icon + dot
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = createStatusIcon(dotColor: .yellow) // Yellow = loading
            button.action = #selector(togglePopover)
            button.target = self

            // Overlay a transparent drop view so audio files can be dragged
            // onto the menu-bar icon. The view's hitTest returns nil so
            // mouse clicks still reach the button (popover toggle).
            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { [weak self] url in
                Task { @MainActor in
                    await AppState.shared.coordinator.transcribeFile(url: url)
                    self?.showPopoverFromDrop()
                }
            }
            button.addSubview(dropView)
        }

        // Create popover with SwiftUI view
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
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
    }
    
    @objc private func handleShowSettings() {
        showSettings()
    }
    
    /// Observe app state changes and update the menu bar icon
    private func setupStateObserver() {
        // Observe transcription state
        appState.$transcriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
        
        // Observe model loaded state
        appState.$isModelLoaded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
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
    
    /// After a drag-drop transcription kicks off, pop the menu open so the
    /// user sees the in-progress state and (shortly) the result.
    private func showPopoverFromDrop() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
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
        window.title = "LocalWhisper Settings"
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
        // Load saved hotkey or use default (Cmd+Shift+Space)
        hotkeyManager.loadSavedHotkey()
        
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
            .appendingPathComponent("Library/Logs/LocalWhisper.log")
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
