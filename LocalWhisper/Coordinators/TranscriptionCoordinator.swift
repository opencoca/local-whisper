import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.localwispr.app", category: "Coordinator")

/// Orchestrates the hotkey → record → transcribe → inject workflow
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    private weak var appState: AppState?
    private var audioService: AudioCaptureService?
    private var transcriptionService: TranscriptionService?
    private var textInjectionService: TextInjectionService?
    private var audioMuteService: AudioMuteService?
    
    private var recordingTask: Task<Void, Never>?
    
    func configure(
        appState: AppState,
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        textInjectionService: TextInjectionService,
        audioMuteService: AudioMuteService
    ) {
        self.appState = appState
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.textInjectionService = textInjectionService
        self.audioMuteService = audioMuteService
    }
    
    /// Called when hotkey is pressed - start recording
    func handleHotkeyPressed() async {
        logger.info("handleHotkeyPressed called")
        
        guard let appState = appState,
              let audioService = audioService else {
            logger.error("appState or audioService is nil")
            return
        }
        
        // Check if model is loaded
        let modelLoaded = await transcriptionService?.isModelLoaded == true
        logger.info("Model loaded: \(modelLoaded)")
        
        guard modelLoaded else {
            appState.errorMessage = "Model not loaded yet. Please wait..."
            logger.warning("Model not loaded, aborting")
            return
        }
        
        // Check permissions
        logger.info("Mic: \(appState.permissionsService.microphoneGranted), Accessibility: \(appState.permissionsService.accessibilityGranted)")
        guard appState.permissionsService.allPermissionsGranted else {
            appState.errorMessage = "Please grant microphone and accessibility permissions"
            return
        }
        
        // If already recording, treat as toggle (stop)
        if appState.transcriptionState == .recording {
            await handleHotkeyReleased()
            return
        }
        
        // Start recording
        do {
            appState.transcriptionState = .recording
            appState.errorMessage = nil
            
            // Mute system audio if enabled (so mic doesn't pick up speaker audio)
            if appState.muteAudioWhileRecording, let audioMuteService = audioMuteService {
                do {
                    try await audioMuteService.muteSystemAudio()
                } catch {
                    // Log but don't fail - muting is optional
                    print("[Coordinator] Failed to mute system audio: \(error)")
                }
            }
            
            try await audioService.startRecording()
            print("[Coordinator] Recording started")
        } catch {
            // Restore audio if we muted it
            if appState.muteAudioWhileRecording, let audioMuteService = audioMuteService {
                try? await audioMuteService.restoreSystemAudio()
            }
            appState.transcriptionState = .error(error.localizedDescription)
            appState.errorMessage = error.localizedDescription
            print("[Coordinator] Failed to start recording: \(error)")
        }
    }
    
    /// Called when hotkey is released - stop recording and transcribe
    func handleHotkeyReleased() async {
        logger.info("handleHotkeyReleased called")
        
        guard let appState = appState,
              let audioService = audioService,
              let transcriptionService = transcriptionService,
              let textInjectionService = textInjectionService else {
            logger.error("Missing dependencies in handleHotkeyReleased")
            return
        }
        
        logger.info("Current state: \(String(describing: appState.transcriptionState))")
        guard appState.transcriptionState == .recording else {
            logger.warning("Not in recording state, skipping")
            return
        }
        
        // Stop recording
        let audioData = await audioService.stopRecording()
        
        // Restore system audio if we muted it
        if appState.muteAudioWhileRecording, let audioMuteService = audioMuteService {
            do {
                try await audioMuteService.restoreSystemAudio()
            } catch {
                print("[Coordinator] Failed to restore system audio: \(error)")
            }
        }
        logger.info("Recording stopped, duration: \(String(format: "%.2f", audioData.duration))s, samples: \(audioData.samples.count)")
        
        // Check if too short
        guard !audioData.isTooShort else {
            appState.transcriptionState = .idle
            appState.errorMessage = "Recording too short"
            return
        }
        
        // Transcribe
        appState.transcriptionState = .transcribing
        
        do {
            let text = try await transcriptionService.transcribe(
                audioData,
                language: appState.language,
                prompt: appState.vocabularyPrompt
            )
            
            logger.info("Transcription result: \(text)")
            appState.lastTranscription = text
            
            // Inject text
            if !text.isEmpty {
                try await textInjectionService.injectText(
                    text,
                    useClipboardFallback: appState.useClipboardFallback
                )
            }
            
            appState.transcriptionState = .idle
            appState.errorMessage = nil
            
        } catch {
            appState.transcriptionState = .error(error.localizedDescription)
            appState.errorMessage = error.localizedDescription
            logger.error("Transcription failed: \(error.localizedDescription)")
            
            // Reset to idle after showing error
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                if case .error = appState.transcriptionState {
                    appState.transcriptionState = .idle
                }
            }
        }
    }
    
    /// Transcribe an audio file from disk.
    /// Parallel to the hotkey flow but skips recording (uses `AudioFileLoader`
    /// instead of `AudioCaptureService`) and skips auto-paste (no focused-app
    /// intent for batch file work). Writes `<url>.txt` next to the source,
    /// copies the text to the clipboard, and updates `lastTranscription` so
    /// the popover shows it.
    func transcribeFile(url: URL) async {
        logger.info("transcribeFile called for \(url.lastPathComponent)")

        guard let appState = appState,
              let transcriptionService = transcriptionService,
              let textInjectionService = textInjectionService else {
            logger.error("Missing dependencies in transcribeFile")
            return
        }

        // Bail out cleanly if a mic recording is already running — file
        // transcription and live recording would race on transcriptionState.
        guard appState.transcriptionState != .recording else {
            appState.errorMessage = "Finish the current recording before transcribing a file"
            return
        }

        // Model must be loaded; same precondition as the hotkey path.
        let modelLoaded = await transcriptionService.isModelLoaded
        guard modelLoaded else {
            appState.errorMessage = "Model not loaded yet. Please wait..."
            return
        }

        appState.transcriptionState = .transcribing
        appState.errorMessage = nil

        do {
            // Load + resample on a background task so the main actor stays responsive.
            let audioData = try await Task.detached(priority: .userInitiated) {
                try AudioFileLoader.load(url: url)
            }.value

            guard !audioData.isTooShort else {
                appState.transcriptionState = .idle
                appState.errorMessage = "Audio file is too short"
                return
            }

            let text = try await transcriptionService.transcribe(
                audioData,
                language: appState.language,
                prompt: appState.vocabularyPrompt
            )

            logger.info("File transcription result: \(text)")
            appState.lastTranscription = text

            if !text.isEmpty {
                // Clipboard for quick reuse — same NSPasteboard pattern as
                // TextInjectionService.copyToClipboard, but no Cmd+V paste.
                await textInjectionService.copyToClipboard(text)

                // Sibling .txt next to the source file. UTF-8, overwrites
                // any prior run so re-transcribing the same file is idempotent.
                let outURL = url.appendingPathExtension("txt")
                do {
                    try text.write(to: outURL, atomically: true, encoding: .utf8)
                    logger.info("Wrote transcript to \(outURL.path)")
                } catch {
                    // Soft-fail: the user still has the text in clipboard + popover.
                    logger.error("Failed to write transcript file: \(error.localizedDescription)")
                }
            }

            appState.transcriptionState = .idle
        } catch {
            appState.transcriptionState = .error(error.localizedDescription)
            appState.errorMessage = error.localizedDescription
            logger.error("File transcription failed: \(error.localizedDescription)")

            // Auto-reset to idle after the error has been visible, matching
            // the hotkey-path behavior.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .error = appState.transcriptionState {
                    appState.transcriptionState = .idle
                }
            }
        }
    }

    /// Cancel current operation
    func cancel() async {
        guard let appState = appState,
              let audioService = audioService else { return }
        
        if appState.transcriptionState == .recording {
            _ = await audioService.stopRecording()
            
            // Restore system audio if we muted it
            if appState.muteAudioWhileRecording, let audioMuteService = audioMuteService {
                try? await audioMuteService.restoreSystemAudio()
            }
        }
        
        recordingTask?.cancel()
        appState.transcriptionState = .idle
    }
}
