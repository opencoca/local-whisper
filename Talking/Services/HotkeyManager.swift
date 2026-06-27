import Foundation
import AppKit
import Carbon.HIToolbox
import ObjectiveC
import os.log

private let hotkeyLogger = Logger(subsystem: "is.sage.talking", category: "HotkeyManager")

/// Append a one-line entry to `~/Library/Logs/Talking.log`. Mirrors
/// `AppDelegate.log()` so HotkeyManager start/stop outcomes show up next
/// to the other startup lines — crucial for diagnosing the "I granted
/// Accessibility but hotkeys still don't work" failure mode without
/// requiring Console.app. The duplication with AppDelegate is deliberate:
/// extracting a shared helper would couple two files that otherwise have
/// no reason to know about each other.
private func hotkeyLogToFile(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Talking.log")
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

/// A "double-tap a modifier key" gesture, mirroring macOS Dictation's
/// "Press ⌃/⌘ twice" trigger. `.off` disables it for a lane. ⌃/⌘/⌥ are
/// detected on the CGEvent tap; 🌐 (Fn) is only reliable through the
/// NSEvent monitor, so it's detected there.
enum DoubleTapModifier: String, CaseIterable, Identifiable {
    case off, control, command, option, fn

    var id: String { rawValue }

    /// Short label for the Settings picker.
    var label: String {
        switch self {
        case .off:     return "Off"
        case .control: return "⌃⌃"
        case .command: return "⌘⌘"
        case .option:  return "⌥⌥"
        case .fn:      return "🌐🌐"
        }
    }

    /// The CGEventFlags bit this gesture watches, or nil when off.
    var flag: CGEventFlags? {
        switch self {
        case .off:     return nil
        case .control: return .maskControl
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .fn:      return .maskSecondaryFn
        }
    }
}

private extension CGEventFlags {
    /// Count of tracked modifier bits set (⌃⌘⌥⇧Fn) — used to tell a lone
    /// modifier tap apart from a chord.
    var trackedModifierCount: Int {
        var n = 0
        for m in [CGEventFlags.maskControl, .maskCommand, .maskAlternate,
                  .maskShift, .maskSecondaryFn] where contains(m) { n += 1 }
        return n
    }
}

/// Manages global keyboard shortcuts using CGEvent API.
///
/// Supports three independent hotkeys on a single event tap:
/// - **Hold** (`keyCode` / `modifiers`, default Ctrl+Shift+Space): fires
///   `onKeyDown` / `onKeyUp` as the user holds and releases. Used by the
///   batch-recording flow.
/// - **Live** (`liveKeyCode` / `liveModifiers`, default Ctrl+Option+Space):
///   fires `onLiveKeyDown` only. Live transcription is a toggle, so
///   `onLiveKeyUp` is intentionally left unwired.
/// - **Speak** (`speakKeyCode` / `speakModifiers`, default
///   Ctrl+Option+Shift+Space): fires `onSpeakKeyDown` once per press.
///   Used by the v1.2.0 speak lane — coordinator resolves selection
///   or clipboard and starts TTS playback.
final class HotkeyManager {
    static let shared = HotkeyManager()

    // Hold hotkey (default Ctrl+Shift+Space)
    private(set) var keyCode: UInt16 = UInt16(kVK_Space)
    private(set) var modifiers: CGEventFlags = [.maskControl, .maskShift]

    // Live hotkey (default Ctrl+Option+Space)
    private(set) var liveKeyCode: UInt16 = UInt16(kVK_Space)
    private(set) var liveModifiers: CGEventFlags = [.maskControl, .maskAlternate]

    // Speak hotkey (default Ctrl+Option+Shift+Space) — v1.2.0
    private(set) var speakKeyCode: UInt16 = UInt16(kVK_Space)
    private(set) var speakModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]

    // Live "stop & return" hotkey — stops live transcription, pastes the
    // transcript into the focused field, then presses Return (send). For
    // dictating quickly into chats. Off by default (nil keyCode) until the
    // user assigns one in Settings → Shortcuts. v1.2.x.
    private(set) var liveStopReturnKeyCode: UInt16?
    private(set) var liveStopReturnModifiers: CGEventFlags = []

    // Double-tap-a-modifier triggers (dictation-style), per lane. Off by
    // default; opt in to ⌃⌃ / ⌘⌘ / ⌥⌥ / 🌐🌐 independently. v1.2.x.
    private(set) var recordDoubleTap: DoubleTapModifier = .off
    private(set) var liveDoubleTap: DoubleTapModifier = .off
    private(set) var speakDoubleTap: DoubleTapModifier = .off
    private(set) var liveStopReturnDoubleTap: DoubleTapModifier = .off

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnKeyMonitor: Any?
    private var fnKeyWasPressed = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onLiveKeyDown: (() -> Void)?
    var onSpeakKeyDown: (() -> Void)?
    var onLiveStopReturn: (() -> Void)?

    // TTS playback controls — the keyboard Play/Pause media key and Esc, gated
    // to only act while TTS is active (otherwise they pass through). v1.2.x.
    var onTogglePlayPauseTTS: (() -> Void)?
    var onStopTTS: (() -> Void)?

    /// Set from `AppState` when speak state changes. Gates the media-key / Esc
    /// playback controls so they only fire — and only consume the key — while
    /// TTS is preparing / speaking / paused. Off otherwise, so Esc and the
    /// media keys behave normally everywhere else.
    var ttsPlaybackActive = false

    private var isKeyDown = false
    private var liveIsKeyDown = false
    private var speakIsKeyDown = false
    private var liveStopReturnIsKeyDown = false

    // Double-tap-a-modifier gesture state. ⌃/⌘/⌥ taps arrive on the CGEvent
    // tap; 🌐/Fn through the NSEvent monitor. A clean lone-modifier press+release
    // is a "tap"; two of the same within `doubleTapWindow` fire the gesture.
    private static let doubleTapModifierMask: CGEventFlags =
        [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
    private var presenceMods: CGEventFlags = []
    private var tapCandidate: CGEventFlags?
    private var tapCandidateValid = false
    private var lastTapFlag: CGEventFlags?
    private var lastTapTime: CFAbsoluteTime = 0
    private let doubleTapWindow: CFAbsoluteTime = 0.30
    private var recordDoubleTapActive = false

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
                                      (1 << CGEventType.flagsChanged.rawValue) |
                                      (1 << 14)  // NX_SYSDEFINED — media (Play/Pause) keys
        
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
        // Only monitor if the Globe/Fn key is the configured hotkey, OR a lane
        // opted into the 🌐🌐 double-tap (the CGEvent tap doesn't see Fn reliably).
        guard keyCode == 179 || keyCode == 63 || anyFnDoubleTap else { return }
        
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
            let fileURL = URL(fileURLWithPath: "/tmp/talking_fn.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: fileURL)
            }
        }
        
        // A clean Fn press/release drives two things: the Globe-as-hold-key
        // lane (only when the hold shortcut actually IS the Globe key), and the
        // Fn double-tap gesture (when any lane opted into 🌐🌐).
        let holdKeyIsGlobe = (keyCode == 63 || keyCode == 179)

        if fnPressed && !hasOtherModifiers && !fnKeyWasPressed {
            fnKeyWasPressed = true
            if holdKeyIsGlobe && !isKeyDown {
                isKeyDown = true
                print("[HotkeyManager] Globe/Fn key DOWN - starting recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            }
        } else if !fnPressed && fnKeyWasPressed {
            fnKeyWasPressed = false
            if holdKeyIsGlobe && isKeyDown {
                isKeyDown = false
                print("[HotkeyManager] Globe/Fn key UP - stopping recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
            // Fn double-tap: a clean Fn tap just completed.
            if anyFnDoubleTap { completeTap(.maskSecondaryFn) }
        } else if fnPressed && hasOtherModifiers {
            // Fn pressed as part of a chord — not a clean tap.
            fnKeyWasPressed = false
            lastTapFlag = nil
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

        // Media keys arrive as NX_SYSDEFINED (type 14), not a named
        // CGEventType, and their keycode lives in the NSEvent payload — handle
        // them before the keyboard logic below.
        if type.rawValue == 14 {
            return handleMediaKey(event)
        }

        let currentKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let currentFlags = event.flags
        
        // Debug: Log ALL events to verify the tap is working
        let debugMsg = "Event: type=\(type.rawValue), keyCode=\(currentKeyCode), flags=\(currentFlags.rawValue)\n"
        if let data = debugMsg.data(using: .utf8) {
            let fileURL = URL(fileURLWithPath: "/tmp/talking_keys.log")
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
        
        // Check whether the current event matches any hotkey. Speak is
        // checked BEFORE hold/live so a superset chord (e.g. the speak
        // default `Ctrl+Option+Shift+Space`) doesn't accidentally trigger
        // the hold or live lanes whose chords are subsets of it.
        let hasSpeakModifiers = checkModifiers(currentFlags, against: speakModifiers)
        let hasHoldModifiers = checkModifiers(currentFlags, against: modifiers)
        let hasLiveModifiers = checkModifiers(currentFlags, against: liveModifiers)

        switch type {
        case .keyDown:
            // A real keypress means any held modifier is part of a chord, not a
            // double-tap — break tap tracking so chords never misfire.
            invalidateDoubleTapTracking()

            // Esc stops TTS while it's playing/paused. Gated on ttsPlaybackActive
            // so Esc is only consumed then — it passes through normally otherwise.
            if currentKeyCode == UInt16(kVK_Escape) && ttsPlaybackActive {
                hotkeyLogger.info("Esc → stop TTS")
                DispatchQueue.main.async { [weak self] in self?.onStopTTS?() }
                return true
            }

            // Speak hotkey — single-press toggle, same shape as live.
            // Resolves to selection-or-clipboard in the coordinator and
            // starts AVSpeechSynthesizer playback. v1.2.0+.
            if currentKeyCode == speakKeyCode && hasSpeakModifiers {
                if !speakIsKeyDown {
                    hotkeyLogger.info("Speak hotkey DOWN detected!")
                    speakIsKeyDown = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onSpeakKeyDown?()
                    }
                }
                return true
            }

            // Live "stop & return" — single press; stops live, pastes, sends.
            // Optional shortcut (nil until assigned). Coordinator no-ops when
            // live isn't active. Same latch shape as live/speak.
            if let srk = liveStopReturnKeyCode,
               currentKeyCode == srk,
               checkModifiers(currentFlags, against: liveStopReturnModifiers) {
                if !liveStopReturnIsKeyDown {
                    hotkeyLogger.info("Live stop&return hotkey DOWN detected!")
                    liveStopReturnIsKeyDown = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onLiveStopReturn?()
                    }
                }
                return true
            }

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
            // Speak hotkey — same poka-yoke as live: clear the latch
            // so the NEXT keyDown is a fresh press, and consume only
            // if we tracked the down so strays pass through.
            if currentKeyCode == speakKeyCode && speakIsKeyDown {
                hotkeyLogger.info("Speak hotkey UP detected (clearing state)")
                speakIsKeyDown = false
                return true
            }

            // Live stop&return — clear the latch so the next press is fresh;
            // consume only if we tracked the down (same poka-yoke as live/speak).
            if let srk = liveStopReturnKeyCode, currentKeyCode == srk, liveStopReturnIsKeyDown {
                hotkeyLogger.info("Live stop&return hotkey UP detected (clearing state)")
                liveStopReturnIsKeyDown = false
                return true
            }

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

            // ⌃/⌘/⌥ double-tap detection (observational; never consumes).
            detectModifierDoubleTap(currentFlags)

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
            // Speak hotkey: same idea.
            if speakIsKeyDown && !hasSpeakModifiers {
                speakIsKeyDown = false
            }
            // Live stop&return: same idea.
            if liveStopReturnIsKeyDown,
               !checkModifiers(currentFlags, against: liveStopReturnModifiers) {
                liveStopReturnIsKeyDown = false
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

    /// Update the speak hotkey (v1.2.0+).
    func setSpeakHotkey(keyCode: UInt16, modifiers: CGEventFlags) {
        self.speakKeyCode = keyCode
        self.speakModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "speakHotkeyKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "speakHotkeyModifiers")
        hotkeyLogger.info("Speak hotkey updated to: \(self.speakShortcutString)")
    }

    /// Load saved speak hotkey from UserDefaults
    func loadSavedSpeakHotkey() {
        if let savedKeyCode = UserDefaults.standard.object(forKey: "speakHotkeyKeyCode") as? Int {
            speakKeyCode = UInt16(savedKeyCode)
        }
        if let savedModifiers = UserDefaults.standard.object(forKey: "speakHotkeyModifiers") as? UInt64 {
            speakModifiers = CGEventFlags(rawValue: savedModifiers)
        }
    }

    /// Assign the live "stop & return" hotkey (v1.2.x+).
    func setLiveStopReturnHotkey(keyCode: UInt16, modifiers: CGEventFlags) {
        self.liveStopReturnKeyCode = keyCode
        self.liveStopReturnModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "liveStopReturnHotkeyKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "liveStopReturnHotkeyModifiers")
        hotkeyLogger.info("Live stop&return hotkey updated to: \(self.liveStopReturnShortcutString)")
    }

    /// Clear the live "stop & return" hotkey (it's optional — off by default).
    func clearLiveStopReturnHotkey() {
        liveStopReturnKeyCode = nil
        liveStopReturnModifiers = []
        UserDefaults.standard.removeObject(forKey: "liveStopReturnHotkeyKeyCode")
        UserDefaults.standard.removeObject(forKey: "liveStopReturnHotkeyModifiers")
        hotkeyLogger.info("Live stop&return hotkey cleared")
    }

    /// Load the saved live "stop & return" hotkey from UserDefaults.
    func loadSavedLiveStopReturnHotkey() {
        if let savedKeyCode = UserDefaults.standard.object(forKey: "liveStopReturnHotkeyKeyCode") as? Int {
            liveStopReturnKeyCode = UInt16(savedKeyCode)
        }
        if let savedModifiers = UserDefaults.standard.object(forKey: "liveStopReturnHotkeyModifiers") as? UInt64 {
            liveStopReturnModifiers = CGEventFlags(rawValue: savedModifiers)
        }
    }

    // MARK: - Double-tap-a-modifier gestures (dictation-style)

    func setRecordDoubleTap(_ mod: DoubleTapModifier) {
        recordDoubleTap = mod
        UserDefaults.standard.set(mod.rawValue, forKey: "recordDoubleTap")
        refreshFnMonitorForDoubleTap()
        hotkeyLogger.info("Record double-tap set to \(mod.rawValue)")
    }

    func setLiveDoubleTap(_ mod: DoubleTapModifier) {
        liveDoubleTap = mod
        UserDefaults.standard.set(mod.rawValue, forKey: "liveDoubleTap")
        refreshFnMonitorForDoubleTap()
        hotkeyLogger.info("Live double-tap set to \(mod.rawValue)")
    }

    func setSpeakDoubleTap(_ mod: DoubleTapModifier) {
        speakDoubleTap = mod
        UserDefaults.standard.set(mod.rawValue, forKey: "speakDoubleTap")
        refreshFnMonitorForDoubleTap()
        hotkeyLogger.info("Speak double-tap set to \(mod.rawValue)")
    }

    func setLiveStopReturnDoubleTap(_ mod: DoubleTapModifier) {
        liveStopReturnDoubleTap = mod
        UserDefaults.standard.set(mod.rawValue, forKey: "liveStopReturnDoubleTap")
        refreshFnMonitorForDoubleTap()
        hotkeyLogger.info("Live stop&return double-tap set to \(mod.rawValue)")
    }

    /// Load saved double-tap gestures from UserDefaults.
    func loadSavedDoubleTaps() {
        if let r = UserDefaults.standard.string(forKey: "recordDoubleTap"),
           let m = DoubleTapModifier(rawValue: r) { recordDoubleTap = m }
        if let r = UserDefaults.standard.string(forKey: "liveDoubleTap"),
           let m = DoubleTapModifier(rawValue: r) { liveDoubleTap = m }
        if let r = UserDefaults.standard.string(forKey: "speakDoubleTap"),
           let m = DoubleTapModifier(rawValue: r) { speakDoubleTap = m }
        if let r = UserDefaults.standard.string(forKey: "liveStopReturnDoubleTap"),
           let m = DoubleTapModifier(rawValue: r) { liveStopReturnDoubleTap = m }
        refreshFnMonitorForDoubleTap()
    }

    /// True when any lane watches the 🌐/Fn double-tap.
    private var anyFnDoubleTap: Bool {
        recordDoubleTap == .fn || liveDoubleTap == .fn || speakDoubleTap == .fn
            || liveStopReturnDoubleTap == .fn
    }

    /// True when any lane watches a ⌃/⌘/⌥ double-tap (the CGEvent-tap path).
    private var anyTapModifierDoubleTap: Bool {
        func isTapModifier(_ m: DoubleTapModifier) -> Bool {
            m == .control || m == .command || m == .option
        }
        return isTapModifier(recordDoubleTap)
            || isTapModifier(liveDoubleTap)
            || isTapModifier(speakDoubleTap)
            || isTapModifier(liveStopReturnDoubleTap)
    }

    /// Fn double-tap needs the NSEvent monitor even when no lane uses the
    /// Globe key as a chord — start it on demand.
    private func refreshFnMonitorForDoubleTap() {
        if anyFnDoubleTap && fnKeyMonitor == nil { startFnKeyMonitor() }
    }

    /// Reset all in-flight tap tracking (used when a real keypress proves a
    /// held modifier was part of a chord).
    private func invalidateDoubleTapTracking() {
        tapCandidate = nil
        tapCandidateValid = false
        lastTapFlag = nil
    }

    /// CGEvent-tap detection for ⌃ / ⌘ / ⌥ double-taps. Observational only —
    /// never consumes the event, so the modifiers keep working normally. Fn is
    /// handled in `handleFnKeyEvent` (the CGEvent tap doesn't see it reliably).
    private func detectModifierDoubleTap(_ flags: CGEventFlags) {
        guard anyTapModifierDoubleTap else { return }

        let present = CGEventFlags(rawValue: flags.rawValue & HotkeyManager.doubleTapModifierMask.rawValue)
        let prev = presenceMods
        presenceMods = present

        if present.isEmpty {
            if let cand = tapCandidate, tapCandidateValid { completeTap(cand) }
            tapCandidate = nil
            tapCandidateValid = false
        } else if present.trackedModifierCount == 1 {
            // Arm only a fresh, single, offered modifier coming from nothing.
            if prev.isEmpty && (present == .maskControl || present == .maskCommand || present == .maskAlternate) {
                tapCandidate = present
                tapCandidateValid = true
            } else if tapCandidate == present && tapCandidateValid {
                // unchanged single-modifier hold — keep the candidate
            } else {
                tapCandidate = nil
                tapCandidateValid = false
            }
        } else {
            // 2+ modifiers held → chord, not a tap.
            tapCandidate = nil
            tapCandidateValid = false
            lastTapFlag = nil
        }
    }

    /// Record a clean modifier tap; if it completes a matching pair inside the
    /// window, fire the gesture.
    private func completeTap(_ flag: CGEventFlags) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastTapFlag == flag && (now - lastTapTime) <= doubleTapWindow {
            lastTapFlag = nil
            fireDoubleTap(flag)
        } else {
            lastTapFlag = flag
            lastTapTime = now
        }
    }

    /// Route a detected double-tap to whichever lane watches that modifier.
    /// Record > Live > Speak precedence if two lanes share a gesture.
    private func fireDoubleTap(_ flag: CGEventFlags) {
        if recordDoubleTap.flag == flag {
            hotkeyLogger.info("Double-tap → record toggle")
            toggleRecordViaDoubleTap()
        } else if liveDoubleTap.flag == flag {
            hotkeyLogger.info("Double-tap → live toggle")
            DispatchQueue.main.async { [weak self] in self?.onLiveKeyDown?() }
        } else if speakDoubleTap.flag == flag {
            hotkeyLogger.info("Double-tap → speak")
            DispatchQueue.main.async { [weak self] in self?.onSpeakKeyDown?() }
        } else if liveStopReturnDoubleTap.flag == flag {
            hotkeyLogger.info("Double-tap → live stop & return")
            DispatchQueue.main.async { [weak self] in self?.onLiveStopReturn?() }
        }
    }

    /// The hold lane is press-and-hold, so a double-tap toggles it: the first
    /// double-tap starts recording, the next stops and transcribes (matching
    /// macOS Dictation's tap-tap-to-start / tap-tap-to-stop feel).
    private func toggleRecordViaDoubleTap() {
        if recordDoubleTapActive {
            recordDoubleTapActive = false
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
        } else {
            recordDoubleTapActive = true
            DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
        }
    }

    // MARK: - Media-key (NX_SYSDEFINED) playback controls

    /// While TTS is active, the keyboard Play/Pause transport key toggles
    /// pause/resume and is consumed (so it doesn't also toggle Music/Spotify).
    /// When TTS isn't active, the key passes straight through to the system.
    private func handleMediaKey(_ event: CGEvent) -> Bool {
        guard ttsPlaybackActive else { return false }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }

        let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
        let keyState = (ns.data1 & 0x0000FF00) >> 8
        let isPress = (keyState == 0x0A)

        // NX_KEYTYPE_PLAY == 16. Only intercept Play/Pause; volume and other
        // media keys pass through untouched.
        guard keyCode == 16 else { return false }

        if isPress {
            hotkeyLogger.info("Media Play/Pause → TTS toggle")
            DispatchQueue.main.async { [weak self] in self?.onTogglePlayPauseTTS?() }
        }
        return true   // consume press and release so the key stays ours while active
    }

    /// Get human-readable shortcut string for the hold hotkey.
    var shortcutString: String { format(keyCode: keyCode, modifiers: modifiers) }

    /// Get human-readable shortcut string for the live hotkey.
    var liveShortcutString: String { format(keyCode: liveKeyCode, modifiers: liveModifiers) }

    /// Get human-readable shortcut string for the speak hotkey.
    var speakShortcutString: String { format(keyCode: speakKeyCode, modifiers: speakModifiers) }

    /// Human-readable string for the optional live "stop & return" hotkey, or
    /// "Not set" when unassigned.
    var liveStopReturnShortcutString: String {
        guard let kc = liveStopReturnKeyCode else { return "Not set" }
        return format(keyCode: kc, modifiers: liveStopReturnModifiers)
    }

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
