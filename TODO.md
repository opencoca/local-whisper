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

- [ ] **Live transcription + dedicated trigger** #api #ux #infra
  - [ ] Verify WhisperKit subsystem properties (`audioEncoder`, `featureExtractor`, etc.) are public for external `AudioStreamTranscriber` construction
  - [ ] `HotkeyManager`: dual-hotkey refactor (hold + live with parallel `setLiveHotkey` / `liveShortcutString`)
  - [ ] `AppState`: persisted (`liveHotkey…`, `autoPasteOnHold`, `autoPasteOnLive`, `liveUseVAD`, `liveSilenceThreshold`, `liveRequiredConfirmationSegments`, `liveWriteTxtSibling`, `liveTxtFolder`, `showPartialConfirmationStyling`) + ephemeral (`liveTranscriptConfirmed`, `liveTranscriptUnconfirmed`, `isLiveActive`)
  - [ ] `LiveTranscriptionService` (NEW): `start(...)` / `stop() -> String` wrapping `AudioStreamTranscriber`
  - [ ] `TranscriptionCoordinator`: `handleLiveHotkey` / `startLive` / `stopLive` with frontmost-app capture + auto-paste gates; interleaving guard on existing hold path
  - [ ] `AppDelegate`: wire live hotkey, extend state observer for `.recording && isLiveActive`, add `.closePopover` notification handler
  - [ ] `MenuBarView`: Start/Stop Live button in `actionsSection`; live attributed transcript in `transcribingSection`
  - [ ] `SettingsView`: second `ShortcutRecorderView` + per-mode auto-paste toggles in Shortcuts tab; new "Live Mode" tab with VAD/threshold/segments/styling/.txt-sibling controls
  - [ ] `make build` clean
  - [ ] `make app` + relaunch
  - [ ] Hold-mode regression check: existing `Ctrl+Shift+Space` flow unchanged
  - [ ] Live via hotkey end-to-end: `Ctrl+Option+Space` toggles, popover opens, text streams, paste lands in target app on stop
  - [ ] Live via popover button end-to-end
  - [ ] Interleaving check: each hotkey ignored while the other path is mid-run
  - [ ] Admin knobs sanity: auto-paste toggles, VAD/threshold/segments visibly affect output, partial-styling toggle works, `.txt` sibling writes to chosen folder
  - [ ] File transcription regression check still works

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
