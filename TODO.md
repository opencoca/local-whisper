# Sage.is Talking — Roadmap

This file tracks active work for the Sage.is Talking menu bar app.

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

- [ ] **Sage.is Talking 1.2.0 — Two-Way Voice + Rebrand** #release #brand #tts #ux
  - Plan at `~/.claude/plans/we-need-to-get-smooth-anchor.md`. Reshapes LocalWhisper from one-way (mic → transcript) into two-way (mic → transcript AND text → speech), rebrands to **Sage.is Talking**, and adds drag-to-transcribe file flow + audio save in both directions + read-along modal — all in one release so users hit one TCC re-grant moment instead of two.
  - **Rebrand canonicals**: app display *Sage.is Talking* / short *Talking*; bundle id proposed `is.sage.talking`; source dir `LocalWhisper/` → `Talking/`; log paths `~/Library/Logs/Talking.log`, `/tmp/talking_keys.log`, `/tmp/talking_fn.log`; dev signing identity `Talking Dev` (legacy `LocalWhisper Dev` left intact for back-compat).
  - **Engine phasing**: v1.2.0 uses **AVSpeechSynthesizer** with Siri-quality voices (Default/Enhanced/Premium/Personal Voice tiers). v2 will add Kokoro CoreML as a downloadable engine. v3 will add Chatterbox voice-cloning via a `chatterbox-cli` brew package (detect-and-use; app stays slim).
  - **Phase 1 — Rebrand commit** (compiles + runs, original feature set, under new name)
    - [ ] `git mv LocalWhisper/ Talking/`
    - [ ] `Package.swift` — rename package + executable target to `Talking`
    - [ ] `scripts/release.sh` — `CFBundleName/CFBundleDisplayName=Sage.is Talking`, `CFBundleIdentifier=is.sage.talking`, DMG `Talking-vX.Y.Z.dmg`
    - [ ] `scripts/ensure-dev-signing-identity.sh` — `Talking Dev` identity (idempotent; keep `LocalWhisper Dev` for back-compat)
    - [ ] `Makefile` — `APP_NAME=Talking`, log paths, `dist/Talking.app`
    - [ ] UI strings: `MenuBarView.swift` header, `SettingsView.swift` (Permissions / Help / About)
    - [ ] Log paths: `TranscriptionService.swift`, `HotkeyManager.swift`, `AppDelegate.swift`
    - [ ] `CLAUDE.md` — Project Overview + log paths + dev-signing identity name
    - [ ] First-launch TCC re-grant banner (lands later with popover work)
    - [ ] `swift build -c release` clean
  - **Phase 2 — Models** (small, isolated)
    - [ ] `Talking/Models/SpeakState.swift` — `.idle / .preparing / .speaking(progress,range) / .paused / .error` (mirrors `TranscriptionState`)
    - [ ] `Talking/Models/SpeakSource.swift` — `.selection / .clipboard / .typed / .file / .url`
    - [ ] `Talking/Models/FileTranscriptionSource.swift` — URL + displayName + durationSeconds
  - **Phase 3 — Services**
    - [ ] `Talking/Services/SpeakService.swift` (NEW) — `actor` wrapping `AVSpeechSynthesizer`; `speak`, `pause`, `resume`, `stop`, `progressStream`, `rangeStream`, `renderToAudioData`
    - [ ] `Talking/Services/AudioExporter.swift` (NEW) — `actor`; single writer for both directions; `.wav` (PCM Float32) and `.m4a` (AAC 64 kbps mono 22 050 Hz)
    - [ ] `Talking/Services/TextSourceService.swift` (NEW) — `actor`; AX selection (`kAXSelectedTextAttribute`), pasteboard, URL fetch + HTML strip, file decode (`String(contentsOf:)` / `PDFKit`)
    - [ ] `Talking/Services/HotkeyManager.swift` — add `speakKeyCode`/`speakModifiers`/`onSpeakKeyDown` + persistence (third lane on the same CGEvent tap)
  - **Phase 4 — Coordinator wiring**
    - [ ] `TranscriptionCoordinator.configure(speakService:textSourceService:audioExporter:)`
    - [ ] `handleSpeakHotkey()`, `startSpeak(source:)`, `stopSpeak()`, `exportSpeakToFile(source:url:format:)`, `exportLastRecording(to:format:)`, `startFileTranscription(_:)`, `stopFileTranscription()`
    - [ ] Stamp `appState.lastRecording = audio` after each successful transcribe; clear on new recording start
    - [ ] File-transcribe chunks ~30 s with ~1 s overlap; appends to `liveTranscriptConfirmed`
  - **Phase 5 — AppState extension** (additive only)
    - [ ] `@Published`: `speakState`, `ttsVoiceID`, `ttsRate`, `ttsPitch`, `ttsDefaultSource`, `readAlongText`, `readAlongRange`, `fileTranscriptionSource`, `fileTranscriptionProgress`, `lastRecording: AudioData?` (transient)
    - [ ] Instantiate `SpeakService`, `TextSourceService`, `AudioExporter` in `init()`
  - **Phase 6 — UI**
    - [ ] `Talking/UI/SpeakPanel.swift` (NEW) — text field, voice picker, rate slider, source buttons (Selection / Clipboard / File / URL), Speak / Pause / Stop, Save Audio…
    - [ ] `MenuBarView.swift` — Transcribe / Speak section toggle; "Speak last transcription" + "Save audio (X s)" buttons on transcription side; "Transcribe a file…" affordance
    - [ ] `LargeLiveTranscriptionView.swift` — mode-aware (live / file / read-along); file header shows displayName + progress bar; read-along renders `AttributedString` with current-word highlight, Pause/Resume/Stop/Save-Audio footer; auto-scroll keeps active word in middle third
    - [ ] `SettingsView.swift` — Voice tab: quality-tier voice picker, rate/pitch sliders, default source, speak-hotkey recorder, "Show read-along window when speaking" toggle (default on); first-launch TCC banner
  - **Phase 7 — AppDelegate**
    - [ ] Wire `HotkeyManager.shared.onSpeakKeyDown = { coordinator.handleSpeakHotkey() }`
    - [ ] `application(_:open:)` routes audio/video UTIs → file-transcribe, text/PDF UTIs → TTS
    - [ ] Menu items: *Speak Selection*, *Speak Clipboard*, *Speak File…*, *Save Speech As…*, *Save Last Recording…* (disabled when `lastRecording == nil`), *Transcribe File…*
  - **Verification** (per plan): Rebrand (Info.plist + TCC re-grant); Side A (all five TTS triggers); Side B (drag/Open/popover-drop file transcribe); Side C (audio export both directions, `.m4a` + `.wav`); Side D (read-along modal, throttled word highlight, font-size/contrast/floating toggles); cross-cutting (logs, quit cleanup)
  - **Out of scope** (tracked for v2 / v3): Kokoro CoreML engine; Chatterbox detect-and-use via brew (`chatterbox-cli` formula in `Sage-is/homebrew-apps`, FastAPI daemon + warm process); Readability article extraction; SRT/VTT export of file transcripts; SSML markup; speaker diarization; Personal Voice creation flow
  - **Release mechanics**: `feature/sage-is-talking-v1` off `develop` (git-flow; never to master). Commit 1 = rebrand only (still compiles). Commits 2–N = functional additions, one per discrete unit. Bump `release.sh` to v1.2.0. PR into `develop`. `release_finish` per the existing flow.

- [ ] **Sage.is Talking for iPhone — minimal standalone iOS app** #ios #cross-platform
  - Mobile research concluded iOS standalone is the highest-leverage cross-platform move: WhisperKit is iOS-native, ~60-65% of macOS Swift LOC ports with cosmetic changes, product shape is "open → dictate → live transcript → copy → swap apps → paste." Differentiation = AGPL + 100% offline + same-app-as-desktop. iOS implementation detail captured inline below (the prior plan-file pointer is stale — the plan file at `~/.claude/plans/we-need-to-get-smooth-anchor.md` now holds the macOS 1.2.0 rebrand + TTS scope above).
  - **Architecture**: same repo; new `TalkingMobile.xcodeproj` alongside `Package.swift`; new `Talking/Mobile/` folder for iOS-only code; `#if os(macOS)` guards in the 2-3 shared files with macOS-isms; macOS Package.swift target excludes `Mobile/`.
  - **Step 1**: Guard shared files cross-platform
    - [ ] `TranscriptionService.swift:175-189` — wrap `~/Library/Logs/Talking.log` in `#if os(macOS)` / use `URL.cachesDirectory` on iOS
    - [ ] `LargeLiveTranscriptionView.swift:44` — guard `Color(nsColor: .windowBackgroundColor)` / use `Color(uiColor: .systemBackground)` on iOS
    - [ ] `AudioCaptureService.swift` — add `#if os(iOS)` branch for `AVAudioSession.setCategory(.record, mode: .measurement)` + `setActive(true)` before `engine.start()`
    - [ ] `make app` clean — macOS build regression check
  - **Step 2**: Bundle `openai_whisper-tiny.en` (~75 MB, four `.mlmodelc` files) into `Talking/Mobile/Resources/Models/` from `argmaxinc/whisperkit-coreml` HuggingFace repo
  - **Step 3**: Create iOS-only files in `Talking/Mobile/`
    - [ ] `TalkingMobileApp.swift` — `@main` App + WindowGroup + MobileAppState
    - [ ] `ContentView.swift` — Tap-to-Record button + LargeLiveTranscriptionView + Copy/Clear buttons + toast
    - [ ] `MobileAppState.swift` — stripped AppState (model/live/vocabulary/font; drop hotkey + OutputMethod + proxy + mute + accessibility)
    - [ ] `MobileCoordinator.swift` — stripped TranscriptionCoordinator (live path only; no TextInjection, no NSRunningApplication)
    - [ ] `MobilePermissionsService.swift` — `AVAudioApplication.requestRecordPermission` only
    - [ ] `SettingsView.swift` — Model section (bundled + downloadable: base / small / large-v3-turbo via `WhisperKit.download`) + Live transcription (font slider, contrast) + About
    - [ ] `Info.plist` — `NSMicrophoneUsageDescription`, supported orientations, no background audio mode
  - **Step 4**: `TalkingMobile.xcodeproj` at repo root — reference (not copy) shared files in `Talking/{Services,Models,UI}/` + include `Talking/Mobile/*.swift`; iOS 16.4 deployment target; WhisperKit via local SPM
  - **Step 5**: `Package.swift` — add `exclude: ["LocalWhisper.entitlements", "Mobile"]`
  - **Step 6**: Rebrand + ship
    - [ ] Lock final name: "Sage.is Talk", "Sage.is Talking", or other Sage.is variant
    - [ ] Rename Xcode target + `CFBundleDisplayName` + bundle ID (e.g. `is.sage.talk`); refresh App Icon if needed
    - [ ] Confirm Apple Developer Program account (opencoca / Sage.is); $99/yr if not paid
    - [ ] Archive → upload via App Store Connect → submit for internal TestFlight review
  - **Verification**:
    - [ ] `make app` macOS still builds clean (regression check after Step 1)
    - [ ] iPhone 15 simulator: app launches, ContentView renders, mic-denied state handled
    - [ ] Physical device: tiny.en transcribes in <1s, transcript styled identically to macOS
    - [ ] Copy round-trip: Copy → Notes → long-press paste → text appears verbatim
    - [ ] Settings → Download base.en → progress UI → model switches → re-transcribe shows accuracy bump
    - [ ] TestFlight upload completes; appears in App Store Connect within ~30 min
  - Effort: 5-7 focused evenings to TestFlight. Time-eaters: Apple Dev account setup (~1 eve if not paid), Xcode signing gremlins (~2-3 hrs), TestFlight review wall-clock (24-48h, not work time).

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
  - [x] `HotkeyManager` — file-log helper (mirrors `AppDelegate.log()`) wired into `start()` and `stop()` outcomes. Was `print`-only; now visible in `~/Library/Logs/Talking.log`. The FAILED-tap line names the canonical fix.
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

*Populated by the TodoScope scanner once it has run. Inline tags in source
that don't yet have a corresponding card here will be grouped under this
heading by area (Services, UI, Coordinators, etc.).*

## Backlog

- [ ] **Cut Sage.is Talking 1.2.0** #release
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

- [ ] **macOS rebrand to Sage.is name (1.2.0)** — *superseded by the In Progress card* #brand #cross-platform
  - The rebrand is now bundled with the v1.2.0 two-way-voice work in the In Progress card above. Items that remain genuinely backlog-only (because they happen *after* the in-app v1.2.0 PR lands) are listed below; everything else moved into the In Progress card's phases.
  - [ ] `homebrew-apps/Casks/local-whisper.rb` → new cask `talking.rb`; deprecate the old cask with a `caveats` pointing at the new one for ~2 releases
  - [ ] `README.md` — title, install command, screenshots
  - [ ] Repo description on GitHub + topics
  - [ ] Possible repo rename (`local-whisper` → `sage-talking` etc.) — separate decision, breaks links so save for last
  - [ ] `CHANGELOG.md` — 1.2.0 entry framing it as rename + TTS + file transcribe + audio export + read-along
  - Note: Bundle ID migration to `is.sage.talking` is part of the In Progress card and accepts the one-time TCC re-grant cost (mitigated by the first-launch banner).

- [ ] **Funding / sponsorship options** #community #infra
  - LocalWhisper is AGPL-3.0 and 100% offline — no paid SaaS hook. Give people who want to support the project a way to.
  - [ ] Decide between (or combine): **GitHub Sponsors** (native button on the repo page, recurring), **Buy Me a Coffee** (one-shot tips, lower friction), **Ko-fi** (similar to BMC), **Open Collective** (transparent / fiscal-hosted), **Patreon** (recurring patronage, heavier audience overhead). Default recommendation: GitHub Sponsors + Buy Me a Coffee for both audiences.
  - [ ] Create `.github/FUNDING.yml` once the platforms are chosen — surfaces the sponsor button on every repo page + PR / issue sidebars (this is the lowest-effort, highest-visibility win)
  - [ ] Add a "Support" or "Sponsor" section near the bottom of `README.md` linking to the chosen platforms
  - [ ] Optional: in-app menu item "Buy me a coffee ☕" (or "Sponsor on GitHub ♥") in the menu-bar popover footer — only worth doing if there's an existing kebab/overflow menu so it doesn't clutter the primary UI
  - [ ] If GitHub Sponsors gets used, set up the sponsor profile (intro pitch, suggested tiers, what tier funds what)
  - [ ] Consider whether contributions should route to `opencoca`, `Sage-is`, or `alexander-somma` — pick before publishing or you'll have to migrate

## Bugs

*No known bugs. Use `// BUG:` inline tags in source to flag defects — they
will surface here automatically once the TodoScope scanner runs.*

## Done

- [x] **Auto-paste regression after Phase 2** #bug — adding a state observer that auto-opened the popover on `.transcribing` was correct for the file path but wrong for the hotkey path: `popover.show(...)` + `NSApp.activate(...)` yanked focus from the user's target app, so the synthetic `Cmd+V` from `TextInjectionService` landed on the popover instead. Fix: gate the auto-open on `AppState.shared.currentFileName != nil` so the hotkey path stays invisible (only the icon dot color signals state, same as it always did). One-condition fix; also dropped the deprecated `ignoringOtherApps:` option in `showPopoverIfHidden`.
- [x] **Stuck-spacebar bug after `Ctrl+Shift+Space` hotkey** #bug — the keyUp handler in `HotkeyManager.handleEvent` consumed every keyUp for the hotkey's keyCode, even ones outside an active hotkey press. After modifiers were released first (clearing `isKeyDown` via the flagsChanged path), or after the user later pressed Space normally, the OS never saw the matching keyUp and treated Space as still-held. Fix: only consume the keyUp when `isKeyDown == true`. KeyUp doesn't generate text, so passing the stray ones through is safe and keeps the OS key-state map in sync.
- [x] **Audio file transcription** #api #ux — drag-drop on menu-bar icon or "Transcribe File…" picker, writes `<file>.txt` sibling, clipboard + popover; verified live with a 90-min `.m4a` interview
- [x] **Startr Makefile bootstrap** #infra — `make help` / `run` / `build` / `app` / `open_app` / `logs` / git-flow-next release & hotfix flow / `things_clean`
- [x] **Custom vocabulary via WhisperKit `promptTokens`** — token-level hints rather than instruction prompts (commit `0fd5875`)
- [x] **App simplification refactor** for reliability (commit `c1d6e5b`)
