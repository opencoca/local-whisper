# Changelog

All notable changes to Sage.is Talking (formerly LocalWhisper) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [1.2.0] — 2026-05-30

### Added

- **Rebrand to Sage.is Talking.** Source directory `LocalWhisper/` → `Talking/`; package + executable + `@main` struct renamed; bundle id `com.localwhisper.app` → `is.sage.talking`; log paths `~/Library/Logs/LocalWhisper.log` → `Talking.log`, `/tmp/localwispr_*` → `/tmp/talking_*`; dev signing identity `LocalWhisper Dev` → `Talking Dev`; About header reads *Sage.is Talking*; menu bar header reads *Talking*.
- **Two-way voice — Speak text aloud.** Dedicated Speak hotkey (default `Ctrl+Option+Shift+Space`) reads selection-first, clipboard-fallback. Popover gains a text field, voice picker, rate + pitch sliders, and source buttons (Selection / Clipboard / File / URL). Pause / Resume / Stop top-level.
- **Three TTS engines.** `AVSpeechSynthesizer` (Default / Enhanced / Premium / Personal Voice tiers), `NSSpeechSynthesizer` (the `say` catalog), and `/usr/bin/say` as a subprocess backend that unlocks Siri voices the in-process synth refuses to load.
- **File transcription.** Drag any audio/video file onto the app icon, drop on the popover, or use *Open File…* to transcribe in ~30 s chunks. Transcript streams into the large window with progress.
- **Audio export — both directions.** *Save Speech As…* writes the configured TTS utterance to `.wav` or `.m4a` without playing. *Save Last Recording…* writes the most recent dictation capture (16 kHz mono Float32 in memory) to disk through the same `AudioExporter`.
- **Read-along modal.** During TTS the large window shows the source text with the active word highlighted and the active sentence centered. Real per-word delegate callbacks for AV / NS; a time-driven simulator for the `say` subprocess.
- **User-tunable `say` calibration.** When the `say` subprocess backend is on, Voice settings expose *Audio start delay* (0–2.00 s, default 0.18 s) and *Speed correction* (0.50×–2.50×, default 1.15×) sliders that shape the read-along highlight timing. Sliders are inert for AV / NS — those engines drive the highlight from Apple's own per-word callbacks.
- **Configurable Speak hotkey** in Settings → Shortcuts, using the same recorder + conflict detection as the record + live hotkeys.

### Changed

- Users upgrading from a `com.localwhisper.app` install will be prompted by macOS to re-grant Accessibility + Microphone once under the new `is.sage.talking` identity. First-launch banner explains the change.
- Large transcription window is now mode-aware: *live transcription* / *file transcription* / *read-along TTS*. Footer controls adapt per mode (Clear+Stop+Copy / Stop+Copy / Pause+Resume+Stop+Save Audio).
- Popover footer shows a gear icon next to *Settings…* and the status-bar click is gated while the large window is being used for live transcription or read-along — clicking the icon surfaces the big window instead of stacking a popover on top of it.
- App icon swapped to the Sage.is brand mark: hex constellation S with a microphone glyph below, on a macOS-style squircle background. The editable composite source is a self-contained `AppIcon.svg` in `Talking/Resources/AppIcon-source/` — both raster sources are inlined as base64 data URIs so position/size edits in any text editor or vector tool are one-file-and-rebuild. `build-icon.sh` re-renders `AppIcon.icns` from the SVG via rsvg-convert + sips + iconutil.

### Fixed

- Read-along centering: previously anchored to the bottom of the modal. Now splits source text into sentences with stable IDs and centers the active sentence as it advances.

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

[Unreleased]: https://github.com/opencoca/local-whisper/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/opencoca/local-whisper/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/opencoca/local-whisper/compare/v1.0.4...v1.1.0
[1.0.4]: https://github.com/opencoca/local-whisper/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/opencoca/local-whisper/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/opencoca/local-whisper/releases/tag/v1.0.2
