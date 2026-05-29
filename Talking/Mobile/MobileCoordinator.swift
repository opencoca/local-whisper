import Foundation
import os.log

private let logger = Logger(subsystem: "is.sage.talking", category: "MobileCoordinator")

/// iOS orchestrator. Strips [TranscriptionCoordinator.swift] to just the
/// live-streaming path: no hotkey hold-record (no global hotkey on iOS),
/// no text injection (iOS uses UIPasteboard.general via the view layer),
/// no frontmost-app refocus (no equivalent on iOS), no mute-speakers
/// (no CoreAudio mute API on iOS).
@MainActor
final class MobileCoordinator: ObservableObject {
    private weak var appState: MobileAppState?
    private var transcriptionService: TranscriptionService?
    private var liveTranscriptionService: LiveTranscriptionService?

    func configure(
        appState: MobileAppState,
        transcriptionService: TranscriptionService,
        liveTranscriptionService: LiveTranscriptionService
    ) {
        self.appState = appState
        self.transcriptionService = transcriptionService
        self.liveTranscriptionService = liveTranscriptionService
    }

    /// Toggle live transcription. The single entry point for the UI's
    /// record/stop button — same gesture starts and stops, so there's no
    /// way for the two paths to drift out of sync.
    func handleLiveHotkey() async {
        guard let appState else { return }
        if appState.isLiveActive {
            await stopLive()
        } else {
            await startLive()
        }
    }

    /// Begin streaming transcription. iOS requires mic permission; if not
    /// granted, surfaces an error rather than silently failing — there's no
    /// hidden recovery path (the user has to grant in Settings).
    func startLive() async {
        guard let appState,
              let transcriptionService,
              let liveTranscriptionService else {
            logger.error("Missing dependencies in startLive")
            return
        }

        let modelLoaded = await transcriptionService.isModelLoaded
        guard modelLoaded else {
            appState.errorMessage = "Model not loaded yet. Please wait…"
            return
        }

        if !appState.permissionsService.microphoneGranted {
            // Try to request once. If still denied, the user must enable in
            // Settings → Privacy → Microphone manually — iOS gives no other path.
            let granted = await appState.permissionsService.requestMicrophonePermission()
            if !granted {
                appState.errorMessage = "Microphone access is required. Enable it in Settings → Talking."
                return
            }
        }

        // Freeze any preserved text from a prior session into confirmed
        // style — that text is no longer being revised. The new session's
        // content appends after a paragraph break so the boundary between
        // recordings stays visually obvious (different breaths, different
        // model contexts; without the break the join often reads weird).
        let priorText: String = {
            let oldConfirmed = appState.liveTranscriptConfirmed
            let oldUnconfirmed = appState.liveTranscriptUnconfirmed
            if oldConfirmed.isEmpty && oldUnconfirmed.isEmpty {
                return ""
            }
            if oldConfirmed.isEmpty { return oldUnconfirmed }
            if oldUnconfirmed.isEmpty { return oldConfirmed }
            return oldConfirmed + " " + oldUnconfirmed
        }()
        let sessionPrefix = priorText.isEmpty ? "" : priorText + "\n\n"

        appState.errorMessage = nil
        appState.liveTranscriptConfirmed = priorText
        appState.liveTranscriptUnconfirmed = ""
        appState.transcriptionStartedAt = Date()
        appState.isLiveActive = true
        appState.transcriptionState = .recording

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
                onUpdate: { [weak appState] confirmed, unconfirmed in
                    guard let appState else { return }
                    // The streamer only knows about THIS session; we prepend
                    // the preserved prior text so the view sees one continuous
                    // transcript across pause/resume cycles.
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

    /// End the audio session. Per "Stop only stops, Clear only clears":
    /// this never touches the displayed transcript — `liveTranscriptConfirmed`
    /// and `liveTranscriptUnconfirmed` stay as-is so the user can review,
    /// copy, or resume by tapping record again. `lastTranscription` is
    /// updated to the full accumulated transcript so the Copy button has
    /// everything in one field.
    func stopLive() async {
        guard let appState,
              let liveTranscriptionService else {
            logger.error("Missing dependencies in stopLive")
            return
        }

        _ = await liveTranscriptionService.stop()
        appState.transcriptionState = .transcribing

        let confirmed = appState.liveTranscriptConfirmed
        let unconfirmed = appState.liveTranscriptUnconfirmed
        let combined: String
        if confirmed.isEmpty && unconfirmed.isEmpty {
            combined = ""
        } else if confirmed.isEmpty {
            combined = unconfirmed
        } else if unconfirmed.isEmpty {
            combined = confirmed
        } else {
            combined = confirmed + " " + unconfirmed
        }
        if !combined.isEmpty {
            appState.lastTranscription = combined
        }

        await resetLiveState()
    }

    /// Only ephemeral session state. Stop = stop, not clear — the displayed
    /// transcript persists until the user hits Clear (or starts a new
    /// session, which appends rather than overwrites).
    private func resetLiveState() async {
        appState?.transcriptionStartedAt = nil
        appState?.isLiveActive = false
        appState?.transcriptionState = .idle
    }
}
