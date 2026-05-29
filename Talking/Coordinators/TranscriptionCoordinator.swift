import Foundation
import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "is.sage.talking", category: "Coordinator")

extension Notification.Name {
    /// Posted by the coordinator when the popover should be dismissed
    /// (currently: just before live-mode focus restore + paste).
    static let closeTalkingPopover = Notification.Name("ClosePopover")
}

/// Orchestrates the hotkey → record → transcribe → inject workflow
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    private weak var appState: AppState?
    private var audioService: AudioCaptureService?
    private var transcriptionService: TranscriptionService?
    private var textInjectionService: TextInjectionService?
    private var audioMuteService: AudioMuteService?
    private var liveTranscriptionService: LiveTranscriptionService?

    private var recordingTask: Task<Void, Never>?

    /// Frontmost app captured at live-mode start so we can refocus it
    /// before pasting on stop. Cleared after paste completes.
    private var liveTargetApp: NSRunningApplication?

    func configure(
        appState: AppState,
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        textInjectionService: TextInjectionService,
        audioMuteService: AudioMuteService,
        liveTranscriptionService: LiveTranscriptionService
    ) {
        self.appState = appState
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.textInjectionService = textInjectionService
        self.audioMuteService = audioMuteService
        self.liveTranscriptionService = liveTranscriptionService
    }
    
    /// Called when hotkey is pressed - start recording
    func handleHotkeyPressed() async {
        logger.info("handleHotkeyPressed called")

        guard let appState = appState,
              let audioService = audioService else {
            logger.error("appState or audioService is nil")
            return
        }

        // Interleaving guard: if live transcription is running, the hold
        // hotkey is a no-op. No double-recording, no contested mic.
        if appState.isLiveActive {
            logger.info("Ignoring hold hotkey — live transcription is active")
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

            // Output dispatch:
            //   - .typeCharacters → keystroke-per-char (works in apps that
            //     block paste). Wins over autoPasteOnHold because the user
            //     explicitly chose typing as the delivery method.
            //   - .paste + autoPasteOnHold = true → clipboard + Cmd+V (default)
            //   - .paste + autoPasteOnHold = false → clipboard only,
            //     user pastes manually.
            if !text.isEmpty {
                switch appState.outputMethod {
                case .typeCharacters:
                    await textInjectionService.typeText(text)
                case .paste:
                    if appState.autoPasteOnHold {
                        try await textInjectionService.injectText(text)
                    } else {
                        await textInjectionService.copyToClipboard(text)
                    }
                }
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

        // Populate the in-progress UI fields before flipping state so the
        // popover (which auto-opens on `.transcribing`) renders the
        // spinner + filename + timer atomically with the state change.
        appState.currentFileName = url.lastPathComponent
        appState.transcriptionStartedAt = Date()
        appState.transcriptionState = .transcribing
        appState.errorMessage = nil

        do {
            // Load + resample on a background task so the main actor stays responsive.
            let audioData = try await Task.detached(priority: .userInitiated) {
                try AudioFileLoader.load(url: url)
            }.value

            guard !audioData.isTooShort else {
                appState.currentFileName = nil
                appState.transcriptionStartedAt = nil
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

            appState.currentFileName = nil
            appState.transcriptionStartedAt = nil
            appState.transcriptionState = .idle
        } catch {
            appState.currentFileName = nil
            appState.transcriptionStartedAt = nil
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

    // MARK: - Live transcription

    /// Single toggle entry point for the live hotkey / popover button.
    /// Bails out if a hold recording is mid-flight (interleaving rule);
    /// otherwise starts or stops the live stream.
    func handleLiveHotkey() async {
        guard let appState = appState else { return }

        // If a hold recording is in progress, ignore — interleaving rule.
        if appState.transcriptionState == .recording && !appState.isLiveActive {
            logger.info("Ignoring live hotkey — hold recording is active")
            return
        }

        if appState.isLiveActive {
            await stopLive()
        } else {
            await startLive()
        }
    }

    /// Begin a streaming live transcription. Captures the currently
    /// frontmost application so we can refocus it before pasting on stop.
    func startLive() async {
        logger.info("startLive called")

        guard let appState = appState,
              let transcriptionService = transcriptionService,
              let liveTranscriptionService = liveTranscriptionService else {
            logger.error("Missing dependencies in startLive")
            return
        }

        // Preconditions: model loaded + accessibility/mic granted.
        let modelLoaded = await transcriptionService.isModelLoaded
        guard modelLoaded else {
            appState.errorMessage = "Model not loaded yet. Please wait..."
            return
        }
        guard appState.permissionsService.allPermissionsGranted else {
            appState.errorMessage = "Please grant microphone and accessibility permissions"
            return
        }

        // Capture target app NOW — before the popover steals focus.
        // Talking itself can be frontmost (e.g., user is clicking
        // popover button); in that case there's no useful target to
        // refocus to, so we leave liveTargetApp nil and skip the paste.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            liveTargetApp = nil
        } else {
            liveTargetApp = frontmost
        }
        logger.info("Live target app: \(self.liveTargetApp?.localizedName ?? "<none>")")

        // Notepad mode preserves prior text across stop/start (mobile-style
        // scratchpad). Other modes are discrete — each session is a fresh slate.
        let priorText: String
        if appState.liveMode == .notepad {
            let oldC = appState.liveTranscriptConfirmed
            let oldU = appState.liveTranscriptUnconfirmed
            if oldC.isEmpty && oldU.isEmpty {
                priorText = ""
            } else if oldC.isEmpty {
                priorText = oldU
            } else if oldU.isEmpty {
                priorText = oldC
            } else {
                priorText = oldC + " " + oldU
            }
        } else {
            priorText = ""
        }
        let sessionPrefix = priorText.isEmpty ? "" : priorText + "\n\n"

        appState.errorMessage = nil
        appState.liveTranscriptConfirmed = priorText
        appState.liveTranscriptUnconfirmed = ""
        appState.transcriptionStartedAt = Date()
        appState.isLiveActive = true
        appState.transcriptionState = .recording

        // The streaming service runs the AudioStreamTranscriber loop in the
        // background; we get callbacks as state ticks.
        guard let whisper = await transcriptionService.whisperKitInstance else {
            appState.errorMessage = "Whisper model isn't ready for streaming yet"
            await resetLiveState()
            return
        }

        do {
            try await liveTranscriptionService.start(
                whisperKit: whisper,
                language: appState.language,
                prompt: appState.vocabularyPrompt,
                useVAD: appState.liveUseVAD,
                silenceThreshold: appState.liveSilenceThreshold,
                requiredSegmentsForConfirmation: appState.liveRequiredConfirmationSegments,
                onUpdate: { [weak self] confirmed, unconfirmed in
                    guard let appState = self?.appState else { return }
                    // Prepend the preserved prefix so the view sees one
                    // continuous transcript across pause/resume cycles
                    // (notepad mode). Other modes use empty prefix.
                    appState.liveTranscriptConfirmed = sessionPrefix + confirmed
                    appState.liveTranscriptUnconfirmed = unconfirmed
                }
            )
        } catch {
            logger.error("Failed to start live transcription: \(error.localizedDescription)")
            appState.errorMessage = error.localizedDescription
            await resetLiveState()
        }
    }

    /// Stop the live stream. Behavior branches on `appState.liveMode`:
    ///   - `.autoPaste` (default): popover closes, target app refocused,
    ///     transcript pasted via Cmd+V or typed.
    ///   - `.clipboardOnly`: popover closes, transcript written to clipboard
    ///     only; user pastes manually wherever they choose.
    ///   - `.notepad`: no clipboard, no paste, popover stays open. Transcript
    ///     persists for review; the next Start continues with a `\n\n`
    ///     boundary. Mobile-style scratchpad on desktop.
    func stopLive() async {
        logger.info("stopLive called (mode: \(self.appState?.liveMode.rawValue ?? "<nil>"))")

        guard let appState = appState,
              let liveTranscriptionService = liveTranscriptionService,
              let textInjectionService = textInjectionService else {
            logger.error("Missing dependencies in stopLive")
            return
        }

        _ = await liveTranscriptionService.stop()

        appState.transcriptionState = .transcribing

        // The user-visible transcript = whatever's currently on screen,
        // including any preserved prefix in notepad mode. We use this for
        // both lastTranscription and the .txt sibling so they match what
        // the user sees.
        let visibleTranscript: String = {
            let c = appState.liveTranscriptConfirmed
            let u = appState.liveTranscriptUnconfirmed
            if c.isEmpty && u.isEmpty { return "" }
            if c.isEmpty { return u }
            if u.isEmpty { return c }
            return c + " " + u
        }()

        // Optional: write the transcript out as a timestamped .txt.
        if appState.liveWriteTxtSibling, !visibleTranscript.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let outURL = appState.liveTxtFolder.appendingPathComponent("live-\(stamp).txt")
            do {
                try FileManager.default.createDirectory(at: appState.liveTxtFolder,
                                                       withIntermediateDirectories: true)
                try visibleTranscript.write(to: outURL, atomically: true, encoding: .utf8)
                logger.info("Wrote live transcript to \(outURL.path)")
            } catch {
                logger.error("Failed to write live transcript: \(error.localizedDescription)")
            }
        }

        if !visibleTranscript.isEmpty {
            appState.lastTranscription = visibleTranscript
        }

        // Mode dispatch — only autoPaste / clipboardOnly touch the
        // clipboard or target app. Notepad is purely on-screen.
        switch appState.liveMode {
        case .autoPaste:
            // Close popover before refocusing target — leaving it open
            // would steal Cmd+V.
            NotificationCenter.default.post(name: .closeTalkingPopover, object: nil)
            if !visibleTranscript.isEmpty {
                if let target = liveTargetApp {
                    target.activate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                switch appState.outputMethod {
                case .typeCharacters:
                    await textInjectionService.typeText(visibleTranscript)
                case .paste:
                    if liveTargetApp != nil {
                        try? await textInjectionService.injectText(visibleTranscript)
                    } else {
                        await textInjectionService.copyToClipboard(visibleTranscript)
                    }
                }
            }
        case .clipboardOnly:
            NotificationCenter.default.post(name: .closeTalkingPopover, object: nil)
            if !visibleTranscript.isEmpty {
                await textInjectionService.copyToClipboard(visibleTranscript)
            }
        case .notepad:
            // No clipboard, no paste — but DO close the popover. The large
            // transcription window is the persistent surface in notepad mode;
            // the popover would just sit there empty and steal attention.
            NotificationCenter.default.post(name: .closeTalkingPopover, object: nil)
        }

        await resetLiveState()
    }

    /// Tear down session state. In notepad mode, preserve the displayed
    /// transcript (Stop only stops, Clear only clears). Other modes clear
    /// it as part of the per-session discrete-paste flow.
    private func resetLiveState() async {
        let mode = appState?.liveMode ?? .autoPaste
        if mode != .notepad {
            appState?.liveTranscriptConfirmed = ""
            appState?.liveTranscriptUnconfirmed = ""
        }
        appState?.transcriptionStartedAt = nil
        appState?.isLiveActive = false
        appState?.transcriptionState = .idle
        liveTargetApp = nil
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
