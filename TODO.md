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

- [ ] **Audio file transcription** #api #ux
  - [x] Add `AudioFileLoader` service (URL → AudioData via AVAudioFile + 16 kHz resample)
  - [x] Add `TranscriptionCoordinator.transcribeFile(url:)` (reuses existing `TranscriptionService.transcribe`, skips auto-paste)
  - [x] Add "Transcribe File…" button + `NSOpenPanel` in `MenuBarView`
  - [x] Register drag-drop on the menu-bar status-item button (transparent `StatusItemDropView` overlay)
  - [x] Write `<file>.txt` next to source on success, plus clipboard + popover display
  - [ ] `make run` and verify with a sample `.wav` end-to-end
  - [ ] `make app` and verify drag-drop on the menu-bar icon end-to-end

- [ ] **Startr Makefile bootstrap** #infra
  - [x] Create `.todoscope-exclude.csv` with Swift/Xcode defaults
  - [x] Write `Makefile` with help / show_vars / git-flow-next / things_clean / Swift targets
  - [x] `make help` lists every target
  - [x] `make show_vars` resolves OWNER, PROJECT_NAME, BRANCH, TAG sensibly
  - [ ] `make run` succeeds (sanity check on dev loop)
  - [ ] `make app` produces `dist/LocalWhisper.app`

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

- [x] **Custom vocabulary via WhisperKit `promptTokens`** — token-level hints rather than instruction prompts (commit `0fd5875`)
- [x] **App simplification refactor** for reliability (commit `c1d6e5b`)
