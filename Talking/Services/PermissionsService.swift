import Foundation
import AVFoundation
import AppKit

/// Handles checking and requesting macOS permissions
@MainActor
final class PermissionsService: ObservableObject {
    @Published var microphoneGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    /// Fires every 2 s while accessibility is not yet granted. Invalidates
    /// itself the moment `AXIsProcessTrusted()` returns true, so it has
    /// zero overhead once the permission is in place.
    private var accessibilityPollTimer: Timer?

    func checkAllPermissions() async {
        await checkMicrophonePermission()
        checkAccessibilityPermission()
        if !accessibilityGranted {
            startAccessibilityPolling()
        }
    }

    /// Poll `AXIsProcessTrusted()` every 2 s until granted.
    /// Eliminates the "I granted it but the app didn't notice" failure mode
    /// without requiring a restart.
    func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.accessibilityGranted = true
                    self.accessibilityPollTimer?.invalidate()
                    self.accessibilityPollTimer = nil
                }
            }
        }
    }

    // MARK: - Microphone Permission
    
    func checkMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = await requestMicrophonePermission()
        case .denied, .restricted:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }
    }
    
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Accessibility Permission
    
    func checkAccessibilityPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermission() {
        // This opens System Preferences to the Accessibility pane
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    // MARK: - Open System Settings
    
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
