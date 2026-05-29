import SwiftUI
import Combine
import CoreGraphics
import Carbon.HIToolbox

/// Global application state container
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - Published State
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    @Published var modelLoadProgress: Double = 0.0
    @Published var isModelLoaded: Bool = false

    /// When set, SettingsView jumps to this tab index on next appear or change.
    /// The popover sets this before posting `ShowSettings` so the user lands
    /// on the right tab without navigating manually. Cleared by SettingsView
    /// once consumed. Not persisted — ephemeral navigation hint only.
    @Published var settingsDeepLink: Int? = nil

    // Ephemeral progress fields for the in-progress UI. Not persisted —
    // set by the coordinator when a file transcription starts, cleared
    // when it ends. `nil` filename means the hotkey/record path, so the
    // UI hides the filename row in that case.
    @Published var currentFileName: String? = nil
    @Published var transcriptionStartedAt: Date? = nil

    // MARK: - Live transcription — ephemeral
    // Updated by the coordinator on every AudioStreamTranscriber tick.
    // Confirmed = segments WhisperKit considers stable. Unconfirmed = tail
    // still being refined. The popover renders them with different colors
    // when `showPartialConfirmationStyling` is on.
    @Published var liveTranscriptConfirmed: String = ""
    @Published var liveTranscriptUnconfirmed: String = ""
    @Published var isLiveActive: Bool = false
    
    // MARK: - Settings (stored in UserDefaults)
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var customVocabulary: [String] {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }
    @Published var muteAudioWhileRecording: Bool {
        didSet { UserDefaults.standard.set(muteAudioWhileRecording, forKey: "muteAudioWhileRecording") }
    }

    // MARK: - Live-transcription settings (persisted)
    //
    // The live hotkey defaults to Ctrl+Option+Space — same Space key as the
    // hold hotkey for muscle-memory parity, different modifier to keep
    // them unambiguous. Rebindable from Settings → Shortcuts.
    @Published var liveHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(liveHotkeyKeyCode), forKey: "liveHotkeyKeyCode") }
    }
    @Published var liveHotkeyModifiers: CGEventFlags {
        didSet { UserDefaults.standard.set(liveHotkeyModifiers.rawValue, forKey: "liveHotkeyModifiers") }
    }

    // Auto-paste switches per mode. Defaults true so existing behavior is
    // preserved on the hold path; live path also pastes by default.
    @Published var autoPasteOnHold: Bool {
        didSet { UserDefaults.standard.set(autoPasteOnHold, forKey: "autoPasteOnHold") }
    }
    /// What happens on Stop in live mode.
    /// - `.autoPaste`: clipboard + Cmd+V to the focused app; next Start
    ///   clears the display (each session is a discrete dictation).
    /// - `.clipboardOnly`: clipboard write, no paste; next Start clears
    ///   the display. For paste-blocked apps or when you want to choose
    ///   where the text lands.
    /// - `.notepad`: no clipboard write, no paste; next Start CONTINUES
    ///   from the existing transcript (with a `\n\n` boundary). Mirrors
    ///   the iOS experience — the popover/large-window becomes a long-form
    ///   scratchpad. The user copies manually when they're done.
    ///
    /// The combination "auto-paste + accumulate" is intentionally absent:
    /// it would produce duplicates in the target app on every stop. Three
    /// presets cover the legitimate workflows; a footgun combination
    /// simply isn't selectable.
    enum LiveMode: String, CaseIterable {
        case autoPaste
        case clipboardOnly
        case notepad
    }

    @Published var liveMode: LiveMode {
        didSet { UserDefaults.standard.set(liveMode.rawValue, forKey: "liveMode") }
    }

    /// How transcribed text reaches the focused app.
    /// - `.paste`: clipboard + synthesized `Cmd+V`. Fast but some apps
    ///   reject programmatic pastes (password fields, certain banking /
    ///   security apps, some terminal contexts).
    /// - `.typeCharacters`: one synthesized keystroke per Unicode scalar.
    ///   Slow (~5 ms / char) but works universally — looks like real
    ///   typing to the receiving app, no paste detection.
    enum OutputMethod: String, CaseIterable {
        case paste
        case typeCharacters
    }

    @Published var outputMethod: OutputMethod {
        didSet { UserDefaults.standard.set(outputMethod.rawValue, forKey: "outputMethod") }
    }

    // Live-mode VAD + segmentation knobs (passed into AudioStreamTranscriber).
    @Published var liveUseVAD: Bool {
        didSet { UserDefaults.standard.set(liveUseVAD, forKey: "liveUseVAD") }
    }
    @Published var liveSilenceThreshold: Float {
        didSet { UserDefaults.standard.set(liveSilenceThreshold, forKey: "liveSilenceThreshold") }
    }
    @Published var liveRequiredConfirmationSegments: Int {
        didSet { UserDefaults.standard.set(liveRequiredConfirmationSegments, forKey: "liveRequiredConfirmationSegments") }
    }

    // Optional: dump the final live-transcript as a timestamped .txt into a
    // user-chosen folder. Off by default; folder defaults to ~/Documents.
    @Published var liveWriteTxtSibling: Bool {
        didSet { UserDefaults.standard.set(liveWriteTxtSibling, forKey: "liveWriteTxtSibling") }
    }
    @Published var liveTxtFolder: URL {
        didSet { UserDefaults.standard.set(liveTxtFolder.path, forKey: "liveTxtFolder") }
    }

    // Visual: dim the unconfirmed tail in the popover. Some users find the
    // two-tone treatment distracting and prefer a single color.
    @Published var showPartialConfirmationStyling: Bool {
        didSet { UserDefaults.standard.set(showPartialConfirmationStyling, forKey: "showPartialConfirmationStyling") }
    }

    // MARK: - Large Live Transcription Window
    //
    // An accessibility-oriented dedicated window that mirrors the live
    // transcript with large, high-contrast text. Useful for visually
    // impaired users, presentations, and anyone who wants the transcript
    // front-and-centre instead of in the translucent menu-bar popover.

    /// Master toggle: when on, the large window opens automatically when
    /// live transcription starts and closes when it stops.
    @Published var liveLargeWindowEnabled: Bool {
        didSet { UserDefaults.standard.set(liveLargeWindowEnabled, forKey: "liveLargeWindowEnabled") }
    }

    /// Font size (points) for the transcript text in the large window.
    @Published var liveLargeWindowFontSize: Double {
        didSet { UserDefaults.standard.set(liveLargeWindowFontSize, forKey: "liveLargeWindowFontSize") }
    }

    /// When on, confirmed segments render in bold and the unconfirmed tail
    /// in regular weight (rather than just primary/secondary color). Makes
    /// the contrast more legible at a glance.
    @Published var liveLargeWindowHighContrast: Bool {
        didSet { UserDefaults.standard.set(liveLargeWindowHighContrast, forKey: "liveLargeWindowHighContrast") }
    }

    /// Keep the large window above other windows (useful for dictating
    /// while reading from another app).
    @Published var liveLargeWindowFloating: Bool {
        didSet { UserDefaults.standard.set(liveLargeWindowFloating, forKey: "liveLargeWindowFloating") }
    }

    // MARK: - v1.2.0 Two-Way Voice — Speak Lane
    //
    // Transient runtime state (not persisted):

    /// Current state of the speech-synthesis workflow. Mirrors
    /// `transcriptionState` for the speak lane.
    @Published var speakState: SpeakState = .idle

    /// Full text the synthesizer is reading. Drives the read-along
    /// modal body when `speakState.isActive`.
    @Published var readAlongText: String = ""

    /// Character range of the *currently spoken* word inside
    /// `readAlongText`. Updated per word boundary via the SpeakService
    /// rangeStream (throttled to ~30 updates/sec in the observer task).
    @Published var readAlongRange: NSRange? = nil

    /// File currently being transcribed (drag-onto-app or *Open File…*).
    /// Drives the large window header (displayName) and progress bar
    /// (`fileTranscriptionProgress`). Nil when no file flow is active.
    @Published var fileTranscriptionSource: FileTranscriptionSource? = nil

    /// 0...1 progress of the in-flight file transcription. Chunk-grained
    /// (the file is split into ~30 s windows; progress ticks after each).
    @Published var fileTranscriptionProgress: Double = 0

    /// The most recent **hotkey-mode** capture, so the user can save it
    /// via *Save Last Recording…*. Cleared at the start of the next
    /// recording and on app quit — so the "save audio" affordance only
    /// shows when there's something concrete to save.
    ///
    /// Live mode is not represented here today: WhisperKit's
    /// `AudioStreamTranscriber` owns the live capture buffer and
    /// doesn't expose the PCM. Surfacing live audio would mean
    /// teeing the capture node via a parallel tap on
    /// `AudioCaptureService`; tracked as a v1.x follow-up.
    @Published var lastRecording: AudioData? = nil

    // Persisted settings:

    /// `AVSpeechSynthesisVoice.identifier` to use for TTS. Empty string
    /// means "let the synth pick for the system language". Premium /
    /// Enhanced voices appear here only after the user installs them
    /// via *System Settings → Accessibility → Spoken Content → Manage
    /// Voices*.
    @Published var ttsVoiceID: String {
        didSet { UserDefaults.standard.set(ttsVoiceID, forKey: "ttsVoiceID") }
    }

    /// 0.0...1.0 maps onto
    /// `AVSpeechUtteranceMinimumSpeechRate ... AVSpeechUtteranceMaximumSpeechRate`.
    /// Default 0.5 = `AVSpeechUtteranceDefaultSpeechRate`-ish.
    @Published var ttsRate: Double {
        didSet { UserDefaults.standard.set(ttsRate, forKey: "ttsRate") }
    }

    /// 0.5...2.0 maps directly onto `AVSpeechUtterance.pitchMultiplier`.
    /// Default 1.0 = no pitch shift.
    @Published var ttsPitch: Double {
        didSet { UserDefaults.standard.set(ttsPitch, forKey: "ttsPitch") }
    }

    /// Default source for the popover's Speak button when no explicit
    /// source is supplied. Stored as raw string so the enum's
    /// associated-value cases don't need a custom Codable.
    enum DefaultSpeakSource: String, CaseIterable {
        case selectionOrClipboard
        case clipboard
        case typedInput
    }
    @Published var ttsDefaultSource: DefaultSpeakSource {
        didSet { UserDefaults.standard.set(ttsDefaultSource.rawValue, forKey: "ttsDefaultSource") }
    }

    /// Speak hotkey persistence — parallels the live hotkey pattern.
    @Published var speakHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(speakHotkeyKeyCode), forKey: "speakHotkeyKeyCode") }
    }
    @Published var speakHotkeyModifiers: CGEventFlags {
        didSet { UserDefaults.standard.set(speakHotkeyModifiers.rawValue, forKey: "speakHotkeyModifiers") }
    }

    /// When on, the large window opens automatically when the speak
    /// lane goes active (read-along mode). Off → speech plays without
    /// surfacing the window. Default on; users who only want speech in
    /// the background can toggle it off in Settings → Voice.
    @Published var showReadAlongWindow: Bool {
        didSet { UserDefaults.standard.set(showReadAlongWindow, forKey: "showReadAlongWindow") }
    }

    // MARK: - Proxy Settings
    @Published var proxyEnabled: Bool {
        didSet { 
            UserDefaults.standard.set(proxyEnabled, forKey: "proxyEnabled")
            applyProxySettings()
        }
    }
    @Published var proxyHost: String {
        didSet { 
            UserDefaults.standard.set(proxyHost, forKey: "proxyHost")
            applyProxySettings()
        }
    }
    @Published var proxyPort: String {
        didSet { 
            UserDefaults.standard.set(proxyPort, forKey: "proxyPort")
            applyProxySettings()
        }
    }
    @Published var proxyType: ProxyType {
        didSet { 
            UserDefaults.standard.set(proxyType.rawValue, forKey: "proxyType")
            applyProxySettings()
        }
    }
    
    enum ProxyType: String, CaseIterable {
        case http = "HTTP"
        case https = "HTTPS"
        case socks5 = "SOCKS5"
    }
    
    /// Apply proxy settings to environment variables
    func applyProxySettings() {
        if proxyEnabled && !proxyHost.isEmpty && !proxyPort.isEmpty {
            let proxyURL: String
            switch proxyType {
            case .http:
                proxyURL = "http://\(proxyHost):\(proxyPort)"
                setenv("HTTP_PROXY", proxyURL, 1)
                setenv("http_proxy", proxyURL, 1)
            case .https:
                proxyURL = "http://\(proxyHost):\(proxyPort)"
                setenv("HTTPS_PROXY", proxyURL, 1)
                setenv("https_proxy", proxyURL, 1)
                setenv("HTTP_PROXY", proxyURL, 1)
                setenv("http_proxy", proxyURL, 1)
            case .socks5:
                proxyURL = "socks5://\(proxyHost):\(proxyPort)"
                setenv("ALL_PROXY", proxyURL, 1)
                setenv("all_proxy", proxyURL, 1)
            }
            print("[AppState] Proxy configured: \(proxyType.rawValue) \(proxyHost):\(proxyPort)")
        } else {
            // Clear proxy environment variables
            unsetenv("HTTP_PROXY")
            unsetenv("http_proxy")
            unsetenv("HTTPS_PROXY")
            unsetenv("https_proxy")
            unsetenv("ALL_PROXY")
            unsetenv("all_proxy")
            print("[AppState] Proxy disabled")
        }
    }
    
    /// Returns custom vocabulary as a prompt string for the transcription model
    var vocabularyPrompt: String? {
        guard !customVocabulary.isEmpty else { return nil }
        return customVocabulary.joined(separator: ", ")
    }
    
    // MARK: - Services
    let permissionsService: PermissionsService
    let audioService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let textInjectionService: TextInjectionService
    let audioMuteService: AudioMuteService
    let liveTranscriptionService: LiveTranscriptionService
    let speakService: SpeakService
    let textSourceService: TextSourceService
    let audioExporter: AudioExporter
    let coordinator: TranscriptionCoordinator

    private init() {
        // Load settings from UserDefaults
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-base"
        self.language = UserDefaults.standard.string(forKey: "language") ?? "en"
        self.customVocabulary = UserDefaults.standard.stringArray(forKey: "customVocabulary") ?? []
        self.muteAudioWhileRecording = UserDefaults.standard.object(forKey: "muteAudioWhileRecording") as? Bool ?? true

        // Live hotkey defaults to Ctrl+Option+Space.
        self.liveHotkeyKeyCode = UInt16(UserDefaults.standard.object(forKey: "liveHotkeyKeyCode") as? Int ?? kVK_Space)
        if let raw = UserDefaults.standard.object(forKey: "liveHotkeyModifiers") as? UInt64 {
            self.liveHotkeyModifiers = CGEventFlags(rawValue: raw)
        } else {
            self.liveHotkeyModifiers = [.maskControl, .maskAlternate]
        }

        self.autoPasteOnHold = UserDefaults.standard.object(forKey: "autoPasteOnHold") as? Bool ?? true

        // LiveMode: prefer the explicit setting; otherwise derive from the
        // legacy `autoPasteOnLive` UserDefaults key (true → .autoPaste,
        // false → .clipboardOnly) so existing users see no behavior change.
        // The `autoPasteOnLive` and `useClipboardFallback` @Published
        // properties were removed when LiveMode shipped — this one-shot
        // read keeps the migration intact for upgraders.
        if let raw = UserDefaults.standard.string(forKey: "liveMode"),
           let m = LiveMode(rawValue: raw) {
            self.liveMode = m
        } else if UserDefaults.standard.object(forKey: "autoPasteOnLive") != nil {
            self.liveMode = (UserDefaults.standard.bool(forKey: "autoPasteOnLive")) ? .autoPaste : .clipboardOnly
        } else {
            self.liveMode = .autoPaste
        }

        // Default to .paste so existing users see no change in behavior.
        // .typeCharacters is opt-in for apps that block programmatic paste.
        if let raw = UserDefaults.standard.string(forKey: "outputMethod"),
           let m = OutputMethod(rawValue: raw) {
            self.outputMethod = m
        } else {
            self.outputMethod = .paste
        }

        self.liveUseVAD = UserDefaults.standard.object(forKey: "liveUseVAD") as? Bool ?? true
        self.liveSilenceThreshold = (UserDefaults.standard.object(forKey: "liveSilenceThreshold") as? Float) ?? 0.3
        self.liveRequiredConfirmationSegments = (UserDefaults.standard.object(forKey: "liveRequiredConfirmationSegments") as? Int) ?? 2

        self.liveWriteTxtSibling = UserDefaults.standard.object(forKey: "liveWriteTxtSibling") as? Bool ?? false
        let defaultDocs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        if let saved = UserDefaults.standard.string(forKey: "liveTxtFolder"),
           !saved.isEmpty {
            self.liveTxtFolder = URL(fileURLWithPath: saved)
        } else {
            self.liveTxtFolder = defaultDocs
        }

        self.showPartialConfirmationStyling = UserDefaults.standard.object(forKey: "showPartialConfirmationStyling") as? Bool ?? true

        // Large live-transcription window defaults
        // - enabled: off (opt-in; the menu-bar popover is the default UI)
        // - font:    60 pt — readable from across a desk, fits ~5 words per line at default window size
        // - high contrast: on — bold/regular weight contrast helps low-vision users
        // - floating: on — common case is dictating while reading something else
        self.liveLargeWindowEnabled = UserDefaults.standard.object(forKey: "liveLargeWindowEnabled") as? Bool ?? false
        self.liveLargeWindowFontSize = UserDefaults.standard.object(forKey: "liveLargeWindowFontSize") as? Double ?? 60.0
        self.liveLargeWindowHighContrast = UserDefaults.standard.object(forKey: "liveLargeWindowHighContrast") as? Bool ?? true
        self.liveLargeWindowFloating = UserDefaults.standard.object(forKey: "liveLargeWindowFloating") as? Bool ?? true

        // v1.2.0 Two-Way Voice settings (persisted)
        self.ttsVoiceID = UserDefaults.standard.string(forKey: "ttsVoiceID") ?? ""
        self.ttsRate = UserDefaults.standard.object(forKey: "ttsRate") as? Double ?? 0.5
        self.ttsPitch = UserDefaults.standard.object(forKey: "ttsPitch") as? Double ?? 1.0
        if let raw = UserDefaults.standard.string(forKey: "ttsDefaultSource"),
           let m = DefaultSpeakSource(rawValue: raw) {
            self.ttsDefaultSource = m
        } else {
            self.ttsDefaultSource = .selectionOrClipboard
        }
        // Speak hotkey defaults to Ctrl+Option+Shift+Space — the live
        // hotkey's chord plus Shift, so it's unambiguously different
        // from both the hold and live keys.
        self.speakHotkeyKeyCode = UInt16(UserDefaults.standard.object(forKey: "speakHotkeyKeyCode") as? Int ?? kVK_Space)
        if let raw = UserDefaults.standard.object(forKey: "speakHotkeyModifiers") as? UInt64 {
            self.speakHotkeyModifiers = CGEventFlags(rawValue: raw)
        } else {
            self.speakHotkeyModifiers = [.maskControl, .maskAlternate, .maskShift]
        }
        self.showReadAlongWindow = UserDefaults.standard.object(forKey: "showReadAlongWindow") as? Bool ?? true

        // Load proxy settings
        self.proxyEnabled = UserDefaults.standard.bool(forKey: "proxyEnabled")
        self.proxyHost = UserDefaults.standard.string(forKey: "proxyHost") ?? "127.0.0.1"
        self.proxyPort = UserDefaults.standard.string(forKey: "proxyPort") ?? "1087"
        if let proxyTypeRaw = UserDefaults.standard.string(forKey: "proxyType"),
           let type = ProxyType(rawValue: proxyTypeRaw) {
            self.proxyType = type
        } else {
            self.proxyType = .http
        }
        
        self.permissionsService = PermissionsService()
        self.audioService = AudioCaptureService()
        self.transcriptionService = TranscriptionService()
        self.textInjectionService = TextInjectionService()
        self.audioMuteService = AudioMuteService()
        self.liveTranscriptionService = LiveTranscriptionService()
        self.speakService = SpeakService()
        self.textSourceService = TextSourceService()
        self.audioExporter = AudioExporter()
        self.coordinator = TranscriptionCoordinator()

        // Inject dependencies after init
        coordinator.configure(
            appState: self,
            audioService: audioService,
            transcriptionService: transcriptionService,
            textInjectionService: textInjectionService,
            audioMuteService: audioMuteService,
            liveTranscriptionService: liveTranscriptionService,
            speakService: speakService,
            textSourceService: textSourceService,
            audioExporter: audioExporter
        )
        
        // Observe transcription service state
        Task {
            for await progress in transcriptionService.loadProgressStream {
                self.modelLoadProgress = progress
            }
        }
        
        // Apply proxy settings on startup
        applyProxySettings()
    }
}
