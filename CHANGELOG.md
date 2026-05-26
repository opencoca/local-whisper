# Changelog

All notable changes to LocalWhisper are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Live transcription with dedicated hotkey (`Ctrl+Option+Space` by default) — streaming text appears in the popover as you speak, no hold-to-record required.
- Audio file transcription via drag-drop on the menu-bar icon or a "Transcribe File…" picker. Writes a sibling `<file>.txt` and copies to clipboard. Proven with 90+ minute files.
- Large accessibility window for live transcription — opaque, large-font (24-96 pt slider), high-contrast, optionally floating above other apps. Opt-in via Settings → Live Mode.
- Output method picker — choose between **Paste** (clipboard + ⌘V, fast) and **Type one character at a time** (`keyboardSetUnicodeString`, ~5 ms/char, works in 1Password / banking / paste-blocking apps).
- Persistent code-signing identity via `make setup` — creates a self-signed `LocalWhisper Dev` cert in the login keychain so macOS TCC permissions (Accessibility, Microphone) survive every rebuild. The recurring "hotkeys broke again after rebuild" trap is structurally eliminated.
- "Reset & Re-request Permissions" button in Settings → Permissions — one-click recovery for both Accessibility and Microphone, including the `.denied`-stuck state that Sonoma+ leaves no other way out of.
- HotkeyManager start/stop outcomes now log to `~/Library/Logs/LocalWhisper.log` (was `print`-only, invisible in `tail`). Failed tap creation surfaces the canonical recovery hint.
- File-logging `log()` helper at AppDelegate (existing infrastructure now used more consistently).
- Startr.Cloud Makefile conventions adopted — `help` banner with auto-listed targets, dynamic git-derived variables, `show_vars` + `verify` debug helpers, git-flow-next release/hotfix flow, `things_clean`, `internal_tag`, `release_preflight`, `release_all` orchestrator, `setup` target idempotent on rerun.
- Polished DMG with `create-dmg` (background image, app-drop-link, window layout).
- `scripts/release_all.sh` — full release orchestrator (build → idempotent `gh release` → cask update + push to `Sage-is/homebrew-apps`).
- `scripts/ensure-dev-signing-identity.sh` — idempotent creator for the dev signing cert (openssl + PKCS12 legacy mode + `security import`, handling two macOS-version quirks the hard way).
- AGPL-3.0 license with explicit MIT attribution to the upstream fork source (`t2o2/local-whisper`).
- KANBAN.canvas (auto-generated from TODO.md by TodoScope) for visual roadmap.
- `assets/dmg_background.png` generated reproducibly by `scripts/make-dmg-background.swift`.

### Changed

- Default branch migrated from `main` to git-flow standard `develop` (active) + `master` (release-ready). `master` only receives commits via `release_finish` / `hotfix_finish`. CI workflow + README badge updated to match.
- Dropped hardened runtime (`--options runtime`) from the codesign invocation — it requires entitlements (`com.apple.security.device.audio-input`) the app doesn't ship, and was silently blocking the Microphone permission prompt. Re-add at notarization time alongside the entitlements file.
- `useClipboardFallback` plumbing was historical and dead — replaced by the explicit `OutputMethod` enum. The Bool no longer exists in `AppState`, `TranscriptionCoordinator`, or `TextInjectionService`.
- Popover behavior gates on transcription state — auto-opens for file transcription (so the user sees progress) but stays hidden for the hotkey path (so the auto-paste lands where the user is typing, not on our popover).
- README installation and contribution sections rewritten; status line + badges aligned with the new branch convention.

### Fixed

- Hotkey + auto-paste no longer breaks after every dev rebuild — root cause was ad-hoc signing churning the TCC identity on every `make app`. Now fixed at the source via the persistent `LocalWhisper Dev` cert.
- `HotkeyManager.start()` can no longer silently fail in the log — the `start() aborted — AXIsProcessTrusted() == false` and `start() FAILED — both HID and session tapCreate returned nil` lines name the exact recovery step.
- `AVCaptureDevice.authorizationStatus` getting stuck at `.denied` after `tccutil reset Microphone` — recoverable via the in-app "Reset & Re-request Permissions" button.

### Removed

- Dead `AudioData.isTooLong` accessor (~30 min cap that was never called).
- `useClipboardFallback` setting (see Changed).

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

[Unreleased]: https://github.com/opencoca/local-whisper/compare/v1.0.4...HEAD
[1.0.4]: https://github.com/opencoca/local-whisper/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/opencoca/local-whisper/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/opencoca/local-whisper/releases/tag/v1.0.2
