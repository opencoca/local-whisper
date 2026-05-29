# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Sage.is Talking** (codebase repo still named `local-whisper`; rebranded from LocalWhisper in v1.2.0) is a macOS menu bar app for 100% offline voice work using WhisperKit + AVSpeechSynthesizer. Hold a hotkey to record, release to transcribe, and text is auto-pasted into the focused app. From v1.2.0 it also speaks selection/clipboard/typed/file/URL text, transcribes dragged-in audio/video files in a large modal, saves audio in both directions, and shows a read-along highlight. Requires macOS 14+ on Apple Silicon.

## Build Commands

```bash
swift build                # Debug build
swift build -c release     # Release build
swift run                  # Build and run
open Package.swift         # Open in Xcode
```

There are no tests to run. CI (`swift build -c release`) only verifies the binary compiles.

## Architecture

### Data Flow

The core workflow is: **Hotkey press -> Record audio -> Transcribe -> Inject text**

```
HotkeyManager (CGEvent tap)
  -> TranscriptionCoordinator (orchestrator, @MainActor)
    -> AudioCaptureService (AVAudioEngine, 16kHz mono Float32)
    -> TranscriptionService (WhisperKit actor)
    -> TextInjectionService (clipboard + simulated Cmd+V)
```

### Concurrency Model

- **Swift actors**: `AudioCaptureService`, `TranscriptionService`, `TextInjectionService`, `AudioMuteService` are all actors for thread safety
- **@MainActor**: `AppState`, `TranscriptionCoordinator`, `PermissionsService`, `AppDelegate`, all UI views
- `AppState.shared` is the singleton state container; services are created in its `init()` and wired into `TranscriptionCoordinator` via `configure()`

### App Lifecycle

The app runs as a menu bar accessory (`NSApp.setActivationPolicy(.accessory)`) with no dock icon. `TalkingApp` (`Talking/App/TalkingApp.swift`) uses `@NSApplicationDelegateAdaptor` to delegate to `AppDelegate`, which owns the `NSStatusItem`, popover, and settings window. The SwiftUI `MenuBarExtra` scene exists but renders `EmptyView` -- all menu bar UI is managed by AppDelegate directly.

### Hotkey System

`HotkeyManager` uses a `CGEvent.tapCreate` at HID level (`.cghidEventTap`) to intercept key events before macOS processes them. It supports hold-to-record (key down starts, key up stops) and toggle mode. Globe/Fn key detection uses a parallel `NSEvent` monitor since CGEvent doesn't reliably capture it. Default shortcut: `Ctrl+Shift+Space`.

### Text Injection

`TextInjectionService` always uses clipboard + simulated `Cmd+V` paste via `CGEvent`. The `useClipboardFallback` setting name is historical -- clipboard-paste is now the only injection method.

### Settings Persistence

Settings use manual `UserDefaults` get/set in `AppState` `@Published` property `didSet` observers (not `@AppStorage`). When adding a new setting: add `@Published` property with `didSet` to `AppState`, load default in `init()`, add UI in `SettingsView.swift`.

### Model Loading

`TranscriptionService.loadModel()` downloads from HuggingFace on first use (cached locally after). Uses `useBackgroundDownloadSession: false` for proxy compatibility. Falls back to `openai_whisper-base` if the selected model fails to load.

## Dependencies

- **WhisperKit** (0.9.0+) -- only external dependency (SPM). Provides CoreML-accelerated Whisper transcription.
- The app previously used **KeyboardShortcuts** but now manages hotkeys directly via CGEvent API in `HotkeyManager`.

## Key Constraints

- App sandbox is **disabled** (entitlements) -- required for CGEvent taps and accessibility API
- Requires Microphone and Accessibility permissions at runtime
- Audio format must be 16kHz mono Float32 for WhisperKit compatibility
- Custom vocabulary works via WhisperKit `promptTokens` (token-level hints, not instruction prompts) -- larger models respond better
- Logs write to `~/Library/Logs/Talking.log` and `/tmp/talking_keys.log` (debug key events)

## Dev Signing

`make app` produces a `dist/Talking.app` signed with a persistent self-signed identity named **`Talking Dev`** (legacy `LocalWhisper Dev` identity is preserved on machines that built pre-rebrand). This identity is created once per machine by `make setup` ([scripts/ensure-dev-signing-identity.sh](scripts/ensure-dev-signing-identity.sh)) and lives in the user's login keychain.

**Why this matters:** macOS keys TCC entries (Accessibility, Microphone, etc.) by the cryptographic signing identity, NOT by bundle id or path. If the build is ad-hoc signed (`codesign --sign -`), every rebuild gets a fresh identity and the previously granted Accessibility row is orphaned — hotkeys + auto-paste stop working until the user re-grants in System Settings. With a persistent identity, the grant survives all rebuilds on that machine.

**One-time setup on a fresh box:**

```bash
make setup                                                # creates 'Talking Dev' cert
tccutil reset Accessibility is.sage.talking               # clear orphaned grants from prior ad-hoc builds
tccutil reset Microphone is.sage.talking
make clean && make app && make open_app                   # rebuild and launch
# macOS prompts once for permissions; grant; never need to re-grant.
```

**TCC re-grant on v1.2.0 upgrade:** users coming from a `com.localwhisper.app`-bundle-id install will see the *new* `is.sage.talking` identity as a fresh app and need to re-grant Accessibility + Microphone once. The first-launch banner in the popover explains this. Old TCC rows for `com.localwhisper.app` can be cleared via the same `tccutil reset … com.localwhisper.app` if desired.

If `codesign` prompts for keychain access on the first build, click **Always Allow** — the cert is locked to your machine and you'll never see the prompt again. The cert is NOT committed to git; each contributor generates their own.

## Debugging

Enable verbose WhisperKit logging in `TranscriptionService`:
```swift
whisperKit = try await WhisperKit(model: modelName, verbose: true, logLevel: .debug, ...)
```

Status bar dot colors indicate state: yellow=loading, green=ready, red=recording, blue=transcribing, orange=error.

`HotkeyManager` writes `start()` / `stop()` outcomes to `~/Library/Logs/Talking.log` — `tail` it after any "hotkeys broken" symptom to see whether the event tap actually installed. A `start() FAILED — both HID and session tapCreate returned nil` line is the canonical signal of a stale TCC entry.

## Two-Way Voice (v1.2.0+)

Beyond transcription, the app speaks text via AVSpeechSynthesizer (v1.2.0 baseline; Kokoro CoreML in v2; Chatterbox voice-cloning via `chatterbox-cli` brew tap in v3). The TTS lane is symmetrical to the transcription lane: `SpeakService` mirrors `TranscriptionService`'s actor + progress-stream shape; `AudioExporter` is the single writer for both captured-recording-out and synthesized-speech-out (`.wav` or `.m4a`); `LargeLiveTranscriptionView` becomes mode-aware (live / file-transcribe / read-along TTS). See `~/.claude/plans/we-need-to-get-smooth-anchor.md` for the full v1.2.0 design.
