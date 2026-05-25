# LocalWhisper — Roadmap

This file tracks active work for the LocalWhisper menu bar app.

> **Convention** — Sections below map to kanban columns. Inline source-code
> tags use the same vocabulary so items stay cross-referenced between this
> file and the codebase. `KANBAN.canvas` (if present) auto-generates from
> this file and inline tags — do not hand-edit it.
>
> | Column      | Markdown section          | Inline tag  |
> |-------------|---------------------------|-------------|
> | Backlog     | `## Backlog`              |             |
> | TODO        | `## TODO`                 | `// TODO:`  |
> | In Progress | `## In Progress`          | `// FIXME:` |
> | Bugs        | `## Bugs`                 | `// BUG:`   |
> | Done        | `- [x]` items / `## Done` | —           |
>
> `// DEPRECATED:` tags should be tracked as TODO items for removal at the
> stated version.

## In Progress

- [ ] **Big modal polish + type-don't-paste output method** #ux #accessibility
  - [x] `AppState`: persisted fields (`liveLargeWindowEnabled`, `liveLargeWindowFontSize`, `liveLargeWindowHighContrast`, `liveLargeWindowFloating`)
  - [x] `LargeLiveTranscriptionView.swift` (NEW) — opaque, large-font transcript with confirmed/unconfirmed weight contrast + auto-scroll
  - [x] `AppDelegate`: `showLargeLiveWindow()` / `hideLargeLiveWindow()` tied to the `$isLiveActive` observer; floating-level updated live on preference change
  - [x] `SettingsView` → Live Mode tab: master toggle, font-size slider, high-contrast toggle, keep-above-other-apps toggle
  - [ ] Polish: `AppDelegate.showLargeLiveWindow()` always `.center()`s on open; explicit `isOpaque = true` + `backgroundColor` (belt-and-suspenders against any glassmorphic surface)
  - [ ] Polish: `LargeLiveTranscriptionView` bumps padding to 60H/40V; explicit `.background(Color(nsColor: .windowBackgroundColor))`
  - [ ] Polish: bump `liveLargeWindowFontSize` default 48 → 60 (new installs only; existing UserDefaults unchanged)
  - [ ] New: `AppState.OutputMethod` enum + `outputMethod` @Published with UserDefaults persistence (default `.paste`)
  - [ ] New: `TextInjectionService.typeText(_:)` — CGEvent keystroke-per-character via `keyboardSetUnicodeString`, ~5 ms cadence
  - [ ] New: `TranscriptionCoordinator` branches on `appState.outputMethod` in both `handleHotkeyReleased` and `stopLive` (output=type wins over auto-paste toggles)
  - [ ] New: `SettingsView` → Shortcuts tab — segmented "Output method" picker (Paste / Type one character at a time) with explanatory caption
  - [ ] `make build` clean
  - [ ] `make app` + relaunch
  - [ ] Manual: Live Mode enable → start live → big modal opens, centered, opaque, large readable text; switch apps → window floats; stop → window hides
  - [ ] Manual: Output method = Paste → hold-mode dictation pastes as before (regression check)
  - [ ] Manual: Output method = Type → hold-mode dictation types char-by-char; test in a paste-blocking app (1Password / password field)

- [ ] **Visible Stop button on big modal + drop dead recording-length cap** #ux #accessibility #poka-yoke
  - Live mode has no hard cap (streamer is bounded-memory); the modal's only escape was the hotkey, which is invisible. Add a single, obvious Stop button. Skipped Pause on purpose — `AudioStreamTranscriber` has no native pause; faking it would mislead users about state (anti-poka-yoke). One button > two.
  - [ ] `LargeLiveTranscriptionView` — footer with one prominent Stop button (red, borderedProminent, scales with `liveLargeWindowFontSize`); routes to `appState.coordinator.handleLiveHotkey()` (DRY with hotkey path)
  - [ ] `AudioData` — delete unused `isTooLong` (dead muda; never called anywhere)
  - [ ] `AudioFileLoader.swift` — fix the comment that still cites `AudioData.isTooLong` and the bogus "Whisper caps at 30 min" framing (the 90-min interview in Done proves otherwise)
  - [ ] `make build` clean
  - [ ] Manual: start live → Stop button visible at bottom → click → live ends, transcript delivered per `outputMethod`
  - [ ] Manual: button hit target is large enough at default 60 pt font (sanity check at min 24 pt and max 96 pt)

- [ ] **Stable dev signing + HotkeyManager visibility** #poka-yoke #infra #permissions
  - Root cause: `scripts/release.sh` was ad-hoc signing (`codesign --sign -`) which generates a fresh cryptographic identity on every build. macOS keys TCC by signing identity, so every `make app` orphaned the prior Accessibility grant — hotkeys + auto-paste broke after every rebuild. All previous in-app workarounds (Reset buttons, restart() calls, Combine sinks) were symptom-chasing.
  - [x] `scripts/ensure-dev-signing-identity.sh` (NEW) — creates a persistent self-signed `LocalWhisper Dev` cert in login keychain via openssl + `security import`. Idempotent. Per-machine; not in git.
  - [x] `Makefile` — `setup` target invokes the script after the brew/gh/asset checks
  - [x] `scripts/release.sh` — replaced `--sign -` with `--sign "LocalWhisper Dev" --options runtime --identifier com.localwhisper.app`; fails loudly with "Run: make setup" if the identity is missing
  - [x] `HotkeyManager` — file-log helper (mirrors `AppDelegate.log()`) wired into `start()` and `stop()` outcomes. Was `print`-only; now visible in `~/Library/Logs/LocalWhisper.log`. The FAILED-tap line names the canonical fix.
  - [x] `CLAUDE.md` — new "Dev Signing" section documents the cert + one-time tccutil reset
  - [ ] Manual: `make setup` creates the cert; re-running is a no-op
  - [ ] Manual: `make clean && make app` produces `dist/LocalWhisper.app`; `codesign -dv` shows `Authority=LocalWhisper Dev`
  - [ ] Manual: `tccutil reset Accessibility com.localwhisper.app` + relaunch → macOS prompts once → grant → hotkey + paste work
  - [ ] Manual (THE KEY TEST): `make app && open dist/LocalWhisper.app` → log immediately shows `Accessibility: true` + `start() OK — HID event tap installed`; no re-grant needed; hotkey + paste work on first try

- [ ] **Polished DMG + canonical Startr release flow** #infra #release
  - [ ] `assets/dmg_background.png` — generated by `scripts/make-dmg-background.swift` (Core Graphics PNG, 540×380)
  - [ ] `scripts/release.sh` — swap manual `hdiutil` DMG for `create-dmg` invocation (window, background, volume icon, app-drop-link)
  - [ ] `scripts/release_all.sh` (NEW) — full orchestrator: build → idempotent `gh release` → cask update + push
  - [ ] `Makefile` — add `setup` / `release_preflight` / `release_all` / `internal_tag`; modify `release_finish` to auto-chain into `release_all` for 3-segment tags
  - [ ] `homebrew-apps/Casks/local-whisper.rb` (NEW) — first Cask in the `Sage-is/homebrew-apps` tap; placeholder SHA overwritten by `release_all.sh`
  - [ ] Verify `make help` lists all new targets
  - [ ] Verify `make setup` runs idempotently (no re-installs on second run)
  - [ ] Verify `make release_preflight` fails loudly on dirty tree / missing tool / missing asset; passes silently on clean state
  - [ ] Manual: full dry-run via `make first_release` → `make release_finish` once the user is ready to cut 1.0.0

## TODO

### TodoScope Alignment

- [ ] **TodoScope bootstrap**: Get the repo into TodoScope conventions
  - [x] Create `.todoscope-exclude.csv` with Swift/Xcode defaults
  - [x] Create `TODO.md` with convention header and column structure
  - [x] Run the TodoScope scanner against this repo and verify the kanban board reflects reality
  - [x] Adjust column aliases or exclude paths if the board doesn't match expectations
  - [ ] Migrate any existing inline `// TODO` / `// FIXME` / `// BUG` comments to the canonical `TODO:` / `FIXME:` / `BUG:` form so the scanner picks them up

### Project Health

- [ ] **Test coverage**: There are currently no tests
  - [ ] Decide what surface area is worth testing (audio capture format conversion, hotkey parsing, settings persistence)
  - [ ] Add a `Tests/` target to `Package.swift` and a baseline smoke test
  - [ ] Wire tests into CI alongside `swift build -c release`

### From Codebase (untracked)

_Populated by the TodoScope scanner once it has run. Inline tags in source
that don't yet have a corresponding card here will be grouped under this
heading by area (Services, UI, Coordinators, etc.)._

## Backlog

- [ ] **Cut LocalWhisper 1.0.0** #release
  - [ ] `make setup` on the maintainer's box (one-time install of `gh` + `create-dmg`)
  - [ ] Fork repo to `Startr-Cloud/local-whisper`; update `origin` remote
  - [ ] `make first_release` (creates `release/1.0.0` branch since there's no prior tag)
  - [ ] `make release_finish` → auto-chains to `release_all`: builds polished DMG, creates `v1.0.0` GitHub Release, updates + pushes `Casks/local-whisper.rb` in `Sage-is/homebrew-apps`
  - [ ] Verify install end-to-end: `brew install --cask sage-is/apps/local-whisper`

- [ ] **Canonize the Startr macOS-app release flow** #infra #cross-project
  - [ ] Extract the canonical pieces from TodoScope's pattern: `release_preflight`, `release_all`, `release_finish` auto-chain, `internal_tag`, the `create-dmg` invocation, and the cask-update step in `release_all.sh`
  - [ ] Land them in the `/startr-init` skill (or a new `/startr-release-macos` sibling skill) so future Startr macOS apps adopt them in one command instead of grepping sibling repos
  - [ ] Update LocalWhisper, TodoScope, and any other Startr macOS apps to cite the skill in their Makefile headers (mirror TodoScope's "Conforms to: WEB-Startr.sh/templates/Makefile.base" comment)

- [ ] **Notarization & signed releases**: First-launch friction
  - [ ] Investigate Apple Developer ID signing for the `.dmg`
  - [ ] Notarize releases so users no longer need the right-click "Open" workaround called out in the README

- [ ] **Model management UX**: First-use model download
  - [ ] Surface download progress more clearly in the menu bar UI
  - [ ] Handle proxy / offline cases beyond the current `useBackgroundDownloadSession: false` workaround

## Bugs

_No known bugs. Use `// BUG:` inline tags in source to flag defects — they
will surface here automatically once the TodoScope scanner runs._

## Done

- [x] **Auto-paste regression after Phase 2** #bug — adding a state observer that auto-opened the popover on `.transcribing` was correct for the file path but wrong for the hotkey path: `popover.show(...)` + `NSApp.activate(...)` yanked focus from the user's target app, so the synthetic `Cmd+V` from `TextInjectionService` landed on the popover instead. Fix: gate the auto-open on `AppState.shared.currentFileName != nil` so the hotkey path stays invisible (only the icon dot color signals state, same as it always did). One-condition fix; also dropped the deprecated `ignoringOtherApps:` option in `showPopoverIfHidden`.
- [x] **Stuck-spacebar bug after `Ctrl+Shift+Space` hotkey** #bug — the keyUp handler in `HotkeyManager.handleEvent` consumed every keyUp for the hotkey's keyCode, even ones outside an active hotkey press. After modifiers were released first (clearing `isKeyDown` via the flagsChanged path), or after the user later pressed Space normally, the OS never saw the matching keyUp and treated Space as still-held. Fix: only consume the keyUp when `isKeyDown == true`. KeyUp doesn't generate text, so passing the stray ones through is safe and keeps the OS key-state map in sync.
- [x] **Audio file transcription** #api #ux — drag-drop on menu-bar icon or "Transcribe File…" picker, writes `<file>.txt` sibling, clipboard + popover; verified live with a 90-min `.m4a` interview
- [x] **Startr Makefile bootstrap** #infra — `make help` / `run` / `build` / `app` / `open_app` / `logs` / git-flow-next release & hotfix flow / `things_clean`
- [x] **Custom vocabulary via WhisperKit `promptTokens`** — token-level hints rather than instruction prompts (commit `0fd5875`)
- [x] **App simplification refactor** for reliability (commit `c1d6e5b`)
