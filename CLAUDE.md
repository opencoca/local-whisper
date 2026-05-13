# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LocalWhisper is a macOS menu bar app for 100% offline voice-to-text using WhisperKit. Hold a hotkey to record, release to transcribe, and text is auto-pasted into the focused app. Requires macOS 14+ on Apple Silicon.

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

The app runs as a menu bar accessory (`NSApp.setActivationPolicy(.accessory)`) with no dock icon. `LocalWhisperApp` uses `@NSApplicationDelegateAdaptor` to delegate to `AppDelegate`, which owns the `NSStatusItem`, popover, and settings window. The SwiftUI `MenuBarExtra` scene exists but renders `EmptyView` -- all menu bar UI is managed by AppDelegate directly.

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
- Logs write to `~/Library/Logs/LocalWhisper.log` and `/tmp/localwispr_keys.log` (debug key events)

## Debugging

Enable verbose WhisperKit logging in `TranscriptionService`:
```swift
whisperKit = try await WhisperKit(model: modelName, verbose: true, logLevel: .debug, ...)
```

Status bar dot colors indicate state: yellow=loading, green=ready, red=recording, blue=transcribing, orange=error.
