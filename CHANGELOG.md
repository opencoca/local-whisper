# Changelog

All notable changes to Sage.is Talking (formerly LocalWhisper) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Rebrand to Sage.is Talking.** Source directory `LocalWhisper/` → `Talking/`; package + executable + `@main` struct renamed; bundle id `com.localwhisper.app` → `is.sage.talking`; log paths `~/Library/Logs/LocalWhisper.log` → `Talking.log`, `/tmp/localwispr_*` → `/tmp/talking_*`; dev signing identity `LocalWhisper Dev` → `Talking Dev`; About header reads *Sage.is Talking*; menu bar header reads *Talking*.
- *(more in v1.2.0 — TTS lane, file-transcribe modal, audio export both directions, read-along highlight)*

### Changed

- Users upgrading from a `com.localwhisper.app` install will be prompted by macOS to re-grant Accessibility + Microphone once under the new `is.sage.talking` identity. First-launch banner explains the change.

### Fixed

### Removed

## [1.1.0] — 2026-05-26

### Added

- Live transcription via a dedicated hotkey (default `Ctrl+Option+Space`). Streams text in the popover as you speak.
- Audio file transcription via drag-drop on the menu-bar icon or "Transcribe File…" picker. Writes `<file>.txt` next to the source.
- Large accessibility window for live mode. Opaque, 24-96 pt font slider, high-contrast, optionally floating. Opt-in via Settings → Live Mode.
- Output method picker: **Paste** (⌘V) or **Type one character at a time**. Type mode works in 1Password and other paste-blocking apps.
- Stable dev code-signing via `make setup`. TCC permissions now survive rebuilds.
- "Reset & Re-request Permissions" button in Settings → Permissions for one-click recovery of both Accessibility and Microphone.
- AGPL-3.0 license with MIT attribution to the upstream fork (`t2o2/local-whisper`).

### Changed

- Git-flow branch convention: `develop` (active) + `master` (release-only).

### Fixed

- Hotkey + auto-paste no longer breaks after rebuilds (root cause: ad-hoc signing churning the TCC identity every build).
- Microphone permission stuck on `.denied` after `tccutil reset` is recoverable via the in-app Reset button.

---

## [1.0.4] — 2026-01-28

### Fixed

- Custom vocabulary now works as intended — switched from instruction-style prompts to WhisperKit `promptTokens` for token-level hints. Larger models respond better.

## [1.0.3] — 2026-01-28

### Changed

- App-wide simplification refactor for reliability — fewer moving parts in the recording → transcription → injection pipeline.

### Added

- Settings screenshot in the README.
- Download instructions for GitHub Releases in the README.

## [1.0.2] — 2026-01-26

Initial publicly tagged release.

### Added

- `Ctrl+Shift+Space` hold-to-record hotkey (default), customizable preset shortcuts.
- Globe/Fn key support via parallel NSEvent monitor.
- App icon with microphone + sound-wave design.
- Studio microphone emoji (🎙️) in the menu bar status item.
- Mute-speakers-while-recording option.
- "Mic Key" shortcut preset.

### Changed

- Renamed project from LocalWispr to LocalWhisper.

### Removed

- Sparkle auto-update mechanism (added briefly in the same release cycle then reverted — kept out of v1.0.2 to ship without that complexity).

### Fixed

- `isModelLoaded` state correctly reflects model-load completion.
- CI app-launch step that hung the macOS runner.

[Unreleased]: https://github.com/opencoca/local-whisper/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/opencoca/local-whisper/compare/v1.0.4...v1.1.0
[1.0.4]: https://github.com/opencoca/local-whisper/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/opencoca/local-whisper/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/opencoca/local-whisper/releases/tag/v1.0.2
