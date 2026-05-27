import Foundation
import AVFoundation

/// iOS-only permissions service. Mic only — there is no Accessibility,
/// no global hotkey, no system-settings deep-link equivalent on iOS.
@MainActor
final class MobilePermissionsService: ObservableObject {
    @Published private(set) var microphoneGranted: Bool

    init() {
        if #available(iOS 17.0, *) {
            self.microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            self.microphoneGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// Triggers the system mic-permission prompt the first time it's called.
    /// On subsequent calls (already-decided state), returns the existing
    /// answer without re-prompting — iOS handles that automatically.
    func requestMicrophonePermission() async -> Bool {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        microphoneGranted = granted
        return granted
    }
}
