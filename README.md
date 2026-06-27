# Sage.is Talking

<p align="center">
  <strong>Two-way local voice for macOS</strong><br>
  100% offline transcription and speech • Apple Silicon optimized • Menu bar app
</p>

<p align="center">
  <a href="https://github.com/opencoca/local-whisper/releases/latest"><img src="https://img.shields.io/github/v/release/opencoca/local-whisper" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
</p>

---

Hold a key, speak, release — text shows up wherever you were typing.
Hit another key, select text, and your Mac reads it back. Drag an
audio file in and watch the transcript stream into a big window.
Everything runs on your Mac. Nothing leaves it.

> *Sage.is Talking* was previously named *LocalWhisper*. The codebase
> repo is still at `opencoca/local-whisper`; the cask is
> `sage-is/apps/talking`.

## Install

### With Homebrew (recommended)

Don't have Homebrew yet? Install it first (full instructions at [brew.sh](https://brew.sh)):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install Sage.is Talking:

```bash
brew install --cask sage-is/apps/talking
```

The first install taps [`sage-is/apps`](https://github.com/Sage-is/homebrew-apps) automatically. To upgrade later:

```bash
brew upgrade --cask talking
```

Then open **Sage.is Talking** and grant **Microphone**, **Accessibility**, and **Input Monitoring** permissions.

### From DMG

1. Download the latest `.dmg` from [Releases](https://github.com/opencoca/local-whisper/releases/latest)
2. Drag **Sage.is Talking** to Applications
3. Open it and grant **Microphone**, **Accessibility**, and **Input Monitoring** permissions

> First launch: right-click → Open to get past the unidentified developer warning.

### From source

```bash
git clone https://github.com/opencoca/local-whisper.git
cd local-whisper
swift build && swift run
```

Grant **Microphone**, **Accessibility**, and **Input Monitoring** permissions when prompted.

## Use

- **Transcribe** — hold `Ctrl+Shift+Space`, speak, release. Text is pasted into whatever you were typing in.
- **Speak** — press `Ctrl+Option+Shift+Space` to read the current selection (or clipboard) aloud. Use the popover text field for typed input, drag in `.txt`/`.md`/`.rtf`/`.pdf`, or paste a URL.
- **Transcribe a file** — drag an audio or video file onto the app icon (or use *Transcribe File…*); the transcript streams into a large window.
- **Save audio** — *Save Last Recording…* keeps the audio you just dictated; *Save Speech As…* saves the synthesized version. Both produce `.wav` (PCM) or `.m4a` (AAC).
- **Read along** — while speech plays, the large window shows the text with the current word highlighted (font-size, contrast, and floating toggles all apply).

## Features

- Global hotkeys — record, live transcription, speak
- 🔒 100% offline — no audio or text leaves your Mac
- Fast — CoreML and Neural Engine on Apple Silicon (WhisperKit for transcription; AVSpeechSynthesizer for speech, including the Siri-quality Premium/Enhanced voices once installed via *System Settings → Accessibility → Spoken Content*)
- Auto-inject — transcribed text lands in the focused field
- Custom vocabulary — teach the model your names, brands, and jargon
- Drag-to-transcribe — wav/mp3/m4a/mp4/aac/flac/aiff/caf/ogg/opus all work
- Audio export — both your captured recordings *and* synthesized speech

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- 8 GB RAM minimum, 16 GB+ for large models

## Configuration

Click the menu bar icon to change the hotkey, pick a model (tiny → large-v3), pick a voice, or add custom vocabulary.

Custom vocabulary lives in Settings → Custom Vocabulary. The model treats it as spelling hints, so larger models respond better.

![Sage.is Talking Settings](docs/images/settings.png)

## Automation & external triggers

Drive Talking from a Xencelabs Quick Keys pad, a Stream Deck, Raycast, Shortcuts, or a shell — anything that can open a URL. Talking registers the `talking://` scheme:

| URL | What it does |
| --- | --- |
| `talking://live` | Start live transcription |
| `talking://live-stop` | Stop live (honors your Live mode: paste / clipboard / notepad) |
| `talking://live-stop-return` | Stop live, paste into the focused field, **press Return** — dictate-and-send for chats |
| `talking://speak` | Speak the current selection (or clipboard) |

Try one from a terminal: `open -g talking://live`.

> **Use `open -g` (background open), not plain `open`.** A foreground open *activates* Talking and steals focus from the app you were in — which breaks the whole point: Talking reads your current selection and pastes back into wherever you were (VS Code, a chat, …). `-g` delivers the action without changing the frontmost app.

**Xencelabs Quick Keys / Stream Deck:** these devices inject keystrokes at a level the global hotkey can't see, so point a button at a URL launcher instead of a keystroke. Generate one tiny launcher app per action:

```bash
scripts/make-trigger-apps.sh
```

This writes `Talking Live.app`, `Talking Stop & Return.app`, etc. into `~/Applications/Talking Triggers`. In Quick Keys, set a button's action to *Open Application* and pick one. The launchers are background agents that fire the action via `open -g`, so **they never steal focus** — you stay in your editor/chat and the transcript pastes back where you were.

**Live stop & return** also works without a URL: assign a dedicated hotkey (or a double-tap gesture) under **Settings → Shortcuts**, or turn on **Settings → Live Mode → "Press Return after paste on stop"** to make every auto-paste stop send.

## Documentation

- [Model Guide](docs/models.md) — comparison, benchmarks, recommendations
- [Architecture](docs/architecture.md) — structure and development guide

## Early adopters & feedback

You're early — thank you for that! 🙏 Sage.is Talking is actively evolving, and your feedback shapes where it goes next.

- **Have a Sage.is account?** Reach us through [sage.is/support](https://sage.is/support/) — we'll see it fast.
- **No account?** [Open an issue](https://github.com/opencoca/local-**whisper**/issues/new) on GitHub. Bugs, feature ideas, rough edges — all welcome.

## Privacy

Everything runs locally. No audio leaves the device. No analytics.

## License

- **Pre-fork code** — MIT License, Copyright © 2024 LocalWhisper. See [LICENSE-MIT](LICENSE-MIT).
- **Startr LLC contributions** — AGPL-3.0, Copyright © 2026 Startr LLC. See [LICENSE](LICENSE).

The combined work ships under AGPL-3.0. Modify it, distribute it, or run it as a service and you must release your changes under the same license with source included.

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Swift Whisper with CoreML
- [OpenAI Whisper](https://github.com/openai/whisper) — original model
- [LocalWhisper](https://github.com/t2o2/LocalWhisper) — the pre-fork project this app is built on (MIT)
