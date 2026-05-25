import Foundation
import AppKit
import Carbon.HIToolbox
import ObjectiveC
import os.log

private let hotkeyLogger = Logger(subsystem: "com.localwispr.app", category: "HotkeyManager")

/// Append a one-line entry to `~/Library/Logs/LocalWhisper.log`. Mirrors
/// `AppDelegate.log()` so HotkeyManager start/stop outcomes show up next
/// to the other startup lines — crucial for diagnosing the "I granted
/// Accessibility but hotkeys still don't work" failure mode without
/// requiring Console.app. The duplication with AppDelegate is deliberate:
/// extracting a shared helper would couple two files that otherwise have
/// no reason to know about each other.
private func hotkeyLogToFile(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalWhisper.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [HotkeyManager] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logFile.path) {
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: logFile)
    }
}

/// Manages global keyboard shortcuts using CGEvent API.
///
/// Supports two independent hotkeys on a single event tap:
/// - **Hold** (`keyCode` / `modifiers`, default Ctrl+Shift+Space): fires
///   `onKeyDown` / `onKeyUp` as the user holds and releases. Used by the
///   batch-recording flow.
/// - **Live** (`liveKeyCode` / `liveModifiers`, default Ctrl+Option+Space):
///   fires `onLiveKeyDown` only. Live transcription is a toggle, so
///   `onLiveKeyUp` is intentionally left unwired.
final class HotkeyManager {
    static let shared = HotkeyManager()

    // Hold hotkey (default Ctrl+Shift+Space)
    private(set) var keyCode: UInt16 = UInt16(kVK_Space)
    private(set) var modifiers: CGEventFlags = [.maskControl, .maskShift]

    // Live hotkey (default Ctrl+Option+Space)
    private(set) var liveKeyCode: UInt16 = UInt16(kVK_Space)
    private(set) var liveModifiers: CGEventFlags = [.maskControl, .maskAlternate]

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnKeyMonitor: Any?
    private var fnKeyWasPressed = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onLiveKeyDown: (() -> Void)?

    private var isKeyDown = false
    private var liveIsKeyDown = false

    private init() {}
    
    /// Start monitoring for global hotkey
    func start() {
        guard eventTap == nil else {
            hotkeyLogToFile("start() called but tap already exists — no-op")
            return
        }

        // Check accessibility permission
        guard AXIsProcessTrusted() else {
            print("[HotkeyManager] Accessibility permission not granted")
            hotkeyLogToFile("start() aborted — AXIsProcessTrusted() == false")
            return
        }
        hotkeyLogToFile("start() proceeding — AXIsProcessTrusted() == true")
        
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)
        
        // Create event tap at HID level to intercept before system handlers (like dictation)
        // Using .cghidEventTap captures events at the lowest level, before macOS processes them
        // This allows us to override system shortcuts like F5 (dictation)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,  // HID level - intercepts before system
            place: .headInsertEventTap,  // Insert at head to get first priority
            options: .defaultTap,  // Can modify/consume events
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyManager] Failed to create HID event tap, falling back to session tap")
            // Fallback to session tap if HID tap fails
            guard let sessionTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                print("[HotkeyManager] Failed to create event tap")
                hotkeyLogToFile("start() FAILED — both HID and session tapCreate returned nil. Likely cause: stale TCC entry (signing identity changed). Fix: Settings → Permissions → Reset & Re-prompt Accessibility, then relaunch.")
                return
            }
            eventTap = sessionTap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sessionTap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: sessionTap, enable: true)
                print("[HotkeyManager] Started monitoring with session event tap")
                hotkeyLogToFile("start() OK — session event tap installed")
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[HotkeyManager] Started monitoring with HID event tap (can override system shortcuts)")
            hotkeyLogToFile("start() OK — HID event tap installed")
        }
        
        // Also add NSEvent monitor for Globe/Fn key detection (flagsChanged)
        // This can sometimes catch modifier keys that CGEvent misses
        startFnKeyMonitor()
    }
    
    /// Start monitoring for Globe/Fn key using NSEvent
    private func startFnKeyMonitor() {
        // Only monitor if Globe key (179) or Fn key (63) is the configured hotkey
        guard keyCode == 179 || keyCode == 63 else { return }
        
        // Use BOTH global and local monitors to catch the Fn key
        // Global monitor catches events when app is not focused
        fnKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnKeyEvent(event)
        }
        
        // Also add local monitor for when our app has focus
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnKeyEvent(event)
            return event
        }
        
        // Store local monitor reference (we'll clean it up with the global one)
        objc_setAssociatedObject(self, "localFnMonitor", localMonitor, .OBJC_ASSOCIATION_RETAIN)
        
        print("[HotkeyManager] Started NSEvent monitors for Globe/Fn key")
    }
    
    private func handleFnKeyEvent(_ event: NSEvent) {
        let fnPressed = event.modifierFlags.contains(.function)
        
        // Only check Fn flag - the Globe key sets the .function modifier
        // Also check that NO other modifiers are pressed (pure Globe key press)
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty
        
        // Log for debugging
        let logMsg = "[HotkeyManager] NSEvent flagsChanged: fn=\(fnPressed), other=\(hasOtherModifiers), keyCode=\(event.keyCode), flags=\(event.modifierFlags.rawValue)\n"
        if let data = logMsg.data(using: .utf8) {
            let fileURL = URL(fileURLWithPath: "/tmp/localwispr_fn.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: fileURL)
            }
        }
        
        // Detect Globe/Fn key press and release (only when no other modifiers)
        if fnPressed && !hasOtherModifiers && !fnKeyWasPressed {
            // Fn key just pressed alone
            fnKeyWasPressed = true
            if !isKeyDown {
                isKeyDown = true
                print("[HotkeyManager] Globe/Fn key DOWN - starting recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            }
        } else if !fnPressed && fnKeyWasPressed {
            // Fn key just released
            fnKeyWasPressed = false
            if isKeyDown {
                isKeyDown = false
                print("[HotkeyManager] Globe/Fn key UP - stopping recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
        }
    }
    
    /// Stop monitoring
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        if let monitor = fnKeyMonitor {
            NSEvent.removeMonitor(monitor)
            fnKeyMonitor = nil
        }
        
        // Also remove local monitor
        if let localMonitor = objc_getAssociatedObject(self, "localFnMonitor") {
            NSEvent.removeMonitor(localMonitor)
            objc_setAssociatedObject(self, "localFnMonitor", nil, .OBJC_ASSOCIATION_RETAIN)
        }
        
        eventTap = nil
        runLoopSource = nil
        print("[HotkeyManager] Stopped monitoring")
        hotkeyLogToFile("stop() OK — tap torn down")
    }
    
    /// Handle keyboard event
    fileprivate func handleEvent(_ event: CGEvent) -> Bool {
        let type = event.type
        let currentKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let currentFlags = event.flags
        
        // Debug: Log ALL events to verify the tap is working
        let debugMsg = "Event: type=\(type.rawValue), keyCode=\(currentKeyCode), flags=\(currentFlags.rawValue)\n"
        if let data = debugMsg.data(using: .utf8) {
            let fileURL = URL(fileURLWithPath: "/tmp/localwispr_keys.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: fileURL)
            }
        }
        
        // Debug: Log Fn/Globe key detection (key code 63 or 179)
        // The Globe key on newer Macs can be key code 179 or triggered via Fn (63)
        if currentKeyCode == 63 || currentKeyCode == 179 || currentFlags.contains(.maskSecondaryFn) {
            NSLog("[HotkeyManager] Fn/Globe key detected - keyCode: %d, flags: %llu", currentKeyCode, currentFlags.rawValue)
        }
        
        // Check whether the current event matches either hotkey.
        let hasHoldModifiers = checkModifiers(currentFlags, against: modifiers)
        let hasLiveModifiers = checkModifiers(currentFlags, against: liveModifiers)

        switch type {
        case .keyDown:
            // Hold hotkey — fires on press, recording starts; autorepeat keyDowns
            // are coalesced via the `!isKeyDown` guard.
            if currentKeyCode == keyCode && hasHoldModifiers {
                if !isKeyDown {
                    hotkeyLogger.info("Hold hotkey DOWN detected!")
                    isKeyDown = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onKeyDown?()
                    }
                }
                return true // Always consume the event to prevent character input
            }

            // Live hotkey — single-press toggle; we never wire onLiveKeyUp.
            // Consume autorepeats so a held key doesn't fire toggle repeatedly.
            if currentKeyCode == liveKeyCode && hasLiveModifiers {
                if !liveIsKeyDown {
                    hotkeyLogger.info("Live hotkey DOWN detected!")
                    liveIsKeyDown = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onLiveKeyDown?()
                    }
                }
                return true
            }
            
        case .keyUp:
            // Hold hotkey — only consume the keyUp if we tracked the keyDown.
            // See the stuck-spacebar commit for why this guard matters: consuming
            // strays leaves the OS thinking the key is still held.
            if currentKeyCode == keyCode && isKeyDown {
                hotkeyLogger.info("Hold hotkey UP detected!")
                isKeyDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
                return true
            }

            // Live hotkey — toggle has no onKeyUp callback, but we still need
            // to clear `liveIsKeyDown` so the NEXT keyDown counts as a fresh
            // press (and so autorepeat coalescing works after release).
            // Consume only if we tracked the down — same poka-yoke rule.
            if currentKeyCode == liveKeyCode && liveIsKeyDown {
                hotkeyLogger.info("Live hotkey UP detected (clearing state)")
                liveIsKeyDown = false
                return true
            }
            
        case .flagsChanged:
            // Log all flag changes for debugging Globe key
            let logMsg = "[HotkeyManager] Flags changed: rawValue=\(currentFlags.rawValue), keyCode=\(currentKeyCode), hasFn=\(currentFlags.contains(.maskSecondaryFn))"
            print(logMsg)
            NSLog("%@", logMsg)
            hotkeyLogger.debug("Flags changed: \(currentFlags.rawValue), keyCode: \(currentKeyCode)")
            
            // Check if Globe/Fn key is the trigger (no other key, just the modifier)
            // Globe key sets maskSecondaryFn when pressed
            if keyCode == 63 || keyCode == 179 {
                let fnPressed = currentFlags.contains(.maskSecondaryFn)
                if fnPressed && !isKeyDown {
                    hotkeyLogger.info("Globe/Fn key DOWN detected via flagsChanged!")
                    isKeyDown = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onKeyDown?()
                    }
                    return true
                } else if !fnPressed && isKeyDown {
                    hotkeyLogger.info("Globe/Fn key UP detected via flagsChanged!")
                    isKeyDown = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onKeyUp?()
                    }
                    return true
                }
            }
            
            // Hold hotkey: handle case where modifiers are released before the
            // key itself. We mirror the same poka-yoke as keyUp: only act on
            // events that match a press we're tracking.
            if isKeyDown && !hasHoldModifiers {
                isKeyDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
            // Live hotkey: same idea — clear stale state if the user lets
            // go of a modifier before releasing the key, so the next press
            // is treated as a fresh toggle.
            if liveIsKeyDown && !hasLiveModifiers {
                liveIsKeyDown = false
            }

        default:
            break
        }

        return false // Don't consume the event
    }

    /// Check if current flags match the supplied target modifiers exactly,
    /// ignoring the Fn modifier (which fires on plain typing too).
    private func checkModifiers(_ flags: CGEventFlags, against target: CGEventFlags) -> Bool {
        // Special case: if no modifiers required (e.g. for function keys or Globe key)
        if target.isEmpty || target == .maskSecondaryFn {
            return true
        }

        let flagsWithoutFn = CGEventFlags(rawValue: flags.rawValue & ~CGEventFlags.maskSecondaryFn.rawValue)
        let controlMatch = target.contains(.maskControl) == flagsWithoutFn.contains(.maskControl)
        let shiftMatch   = target.contains(.maskShift)   == flagsWithoutFn.contains(.maskShift)
        let optionMatch  = target.contains(.maskAlternate) == flagsWithoutFn.contains(.maskAlternate)
        let commandMatch = target.contains(.maskCommand) == flagsWithoutFn.contains(.maskCommand)
        return controlMatch && shiftMatch && optionMatch && commandMatch
    }
    
    /// Update the hotkey
    func setHotkey(keyCode: UInt16, modifiers: CGEventFlags) {
        let wasGlobeKey = self.keyCode == 179 || self.keyCode == 63
        
        self.keyCode = keyCode
        self.modifiers = modifiers
        
        // Save to UserDefaults
        UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "hotkeyModifiers")
        
        // Restart Fn key monitor if switching to/from Globe key
        let isGlobeKey = keyCode == 179 || keyCode == 63
        if wasGlobeKey != isGlobeKey {
            // Stop existing Fn monitor
            if let monitor = fnKeyMonitor {
                NSEvent.removeMonitor(monitor)
                fnKeyMonitor = nil
            }
            if let localMonitor = objc_getAssociatedObject(self, "localFnMonitor") {
                NSEvent.removeMonitor(localMonitor)
                objc_setAssociatedObject(self, "localFnMonitor", nil, .OBJC_ASSOCIATION_RETAIN)
            }
            fnKeyWasPressed = false
            
            // Start new Fn monitor if needed
            if isGlobeKey {
                startFnKeyMonitor()
            }
        }
        
        hotkeyLogger.info("Hotkey updated to: \(self.shortcutString)")
    }
    
    /// Load saved hotkey from UserDefaults
    func loadSavedHotkey() {
        if let savedKeyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int {
            keyCode = UInt16(savedKeyCode)
        }
        if let savedModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt64 {
            modifiers = CGEventFlags(rawValue: savedModifiers)
        }
    }

    /// Update the live hotkey
    func setLiveHotkey(keyCode: UInt16, modifiers: CGEventFlags) {
        self.liveKeyCode = keyCode
        self.liveModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "liveHotkeyKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "liveHotkeyModifiers")
        hotkeyLogger.info("Live hotkey updated to: \(self.liveShortcutString)")
    }

    /// Load saved live hotkey from UserDefaults
    func loadSavedLiveHotkey() {
        if let savedKeyCode = UserDefaults.standard.object(forKey: "liveHotkeyKeyCode") as? Int {
            liveKeyCode = UInt16(savedKeyCode)
        }
        if let savedModifiers = UserDefaults.standard.object(forKey: "liveHotkeyModifiers") as? UInt64 {
            liveModifiers = CGEventFlags(rawValue: savedModifiers)
        }
    }
    
    /// Get human-readable shortcut string for the hold hotkey.
    var shortcutString: String { format(keyCode: keyCode, modifiers: modifiers) }

    /// Get human-readable shortcut string for the live hotkey.
    var liveShortcutString: String { format(keyCode: liveKeyCode, modifiers: liveModifiers) }

    private func format(keyCode: UInt16, modifiers: CGEventFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.maskSecondaryFn) { parts.append("🌐") }
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        
        // Convert key code to string
        let keyString: String
        switch Int(keyCode) {
        case kVK_Space: keyString = "Space"
        case kVK_Return: keyString = "Return"
        case kVK_Tab: keyString = "Tab"
        case kVK_Escape: keyString = "Esc"
        case 63: keyString = "🌐"  // Globe/Fn key
        case 179: keyString = "🌐"  // Globe key on newer Macs
        case kVK_F1: keyString = "F1"
        case kVK_F2: keyString = "F2"
        case kVK_F3: keyString = "F3"
        case kVK_F4: keyString = "F4"
        case kVK_F5: keyString = "F5"
        case kVK_F6: keyString = "F6"
        case kVK_F7: keyString = "F7"
        case kVK_F8: keyString = "F8"
        case kVK_F9: keyString = "F9"
        case kVK_F10: keyString = "F10"
        case kVK_F11: keyString = "F11"
        case kVK_F12: keyString = "F12"
        default:
            // Try to get the character
            if let char = keyCodeToString(keyCode) {
                keyString = char.uppercased()
            } else {
                keyString = "Key\(keyCode)"
            }
        }
        
        parts.append(keyString)
        return parts.joined()
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)
        
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}

// MARK: - CGEvent Callback
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    
    // Handle tap disabled event
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotkeyManager.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }
    
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    
    if manager.handleEvent(event) {
        return nil // Consume the event
    }
    
    return Unmanaged.passRetained(event)
}
