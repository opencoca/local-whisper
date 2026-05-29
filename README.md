# Sage.is Talking

<p align="center">
  <strong>Two-way local voice for macOS</strong><br>
  100% offline transcription and speech • Apple Silicon optimized • Menu bar app
</p>

<p align="center">
  <a href="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml"><img src="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
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

### From DMG (recommended)

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

## Documentation

- [Model Guide](docs/models.md) — comparison, benchmarks, recommendations
- [Architecture](docs/architecture.md) — structure and development guide

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
