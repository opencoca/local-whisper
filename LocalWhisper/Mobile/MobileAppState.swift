import SwiftUI
import Combine

/// iOS state container. A clean strip of [AppState.swift] — drops everything
/// macOS-specific (hotkeys, output method, proxy, mute-speakers, accessibility)
/// and keeps the cross-platform transcription pipeline + live-mode UI knobs.
@MainActor
final class MobileAppState: ObservableObject {
    static let shared = MobileAppState()

    // MARK: - Published State
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    @Published var modelLoadProgress: Double = 0.0
    @Published var isModelLoaded: Bool = false

    // Live transcription — ephemeral, written by MobileCoordinator on every tick.
    @Published var liveTranscriptConfirmed: String = ""
    @Published var liveTranscriptUnconfirmed: String = ""
    @Published var isLiveActive: Bool = false

    /// Set when a live session starts so the UI can render a running timer.
    /// Cleared by `MobileCoordinator.resetLiveState()`.
    @Published var transcriptionStartedAt: Date? = nil

    // MARK: - Persisted settings
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var customVocabulary: [String] {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    // Live-mode VAD + segmentation knobs (same as macOS).
    @Published var liveUseVAD: Bool {
        didSet { UserDefaults.standard.set(liveUseVAD, forKey: "liveUseVAD") }
    }
    @Published var liveSilenceThreshold: Float {
        didSet { UserDefaults.standard.set(liveSilenceThreshold, forKey: "liveSilenceThreshold") }
    }
    @Published var liveRequiredConfirmationSegments: Int {
        didSet { UserDefaults.standard.set(liveRequiredConfirmationSegments, forKey: "liveRequiredConfirmationSegments") }
    }

    // Visual: dim the unconfirmed tail. Matches macOS.
    @Published var showPartialConfirmationStyling: Bool {
        didSet { UserDefaults.standard.set(showPartialConfirmationStyling, forKey: "showPartialConfirmationStyling") }
    }

    // Live transcription display knobs (font size + contrast). Drop the
    // "floating window" toggle — iOS has no equivalent.
    @Published var liveLargeWindowFontSize: Double {
        didSet { UserDefaults.standard.set(liveLargeWindowFontSize, forKey: "liveLargeWindowFontSize") }
    }
    @Published var liveLargeWindowHighContrast: Bool {
        didSet { UserDefaults.standard.set(liveLargeWindowHighContrast, forKey: "liveLargeWindowHighContrast") }
    }

    /// Custom vocabulary joined for WhisperKit promptTokens.
    var vocabularyPrompt: String? {
        guard !customVocabulary.isEmpty else { return nil }
        return customVocabulary.joined(separator: ", ")
    }

    // MARK: - Services
    let permissionsService: MobilePermissionsService
    let audioService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let liveTranscriptionService: LiveTranscriptionService
    let coordinator: MobileCoordinator

    private init() {
        // Default model bundled in app resources — see Mobile/Resources/Models/.
        // Plan: tiny.en bundled, base/small/large-v3-turbo downloadable.
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-tiny.en"
        self.language = UserDefaults.standard.string(forKey: "language") ?? "en"
        self.customVocabulary = UserDefaults.standard.stringArray(forKey: "customVocabulary") ?? []

        self.liveUseVAD = UserDefaults.standard.object(forKey: "liveUseVAD") as? Bool ?? true
        self.liveSilenceThreshold = (UserDefaults.standard.object(forKey: "liveSilenceThreshold") as? Float) ?? 0.3
        self.liveRequiredConfirmationSegments = (UserDefaults.standard.object(forKey: "liveRequiredConfirmationSegments") as? Int) ?? 2

        self.showPartialConfirmationStyling = UserDefaults.standard.object(forKey: "showPartialConfirmationStyling") as? Bool ?? true

        // 36pt default — readable at a typical phone reading distance; user
        // can crank up to 96pt for accessibility. Smaller default than
        // macOS (which is 60pt) because phone screens are physically tighter.
        self.liveLargeWindowFontSize = UserDefaults.standard.object(forKey: "liveLargeWindowFontSize") as? Double ?? 36.0
        self.liveLargeWindowHighContrast = UserDefaults.standard.object(forKey: "liveLargeWindowHighContrast") as? Bool ?? true

        self.permissionsService = MobilePermissionsService()
        self.audioService = AudioCaptureService()
        self.transcriptionService = TranscriptionService()
        self.liveTranscriptionService = LiveTranscriptionService()
        self.coordinator = MobileCoordinator()

        coordinator.configure(
            appState: self,
            transcriptionService: transcriptionService,
            liveTranscriptionService: liveTranscriptionService
        )

        // Observe transcription service model-load progress.
        Task {
            for await progress in transcriptionService.loadProgressStream {
                self.modelLoadProgress = progress
            }
        }
    }
}
