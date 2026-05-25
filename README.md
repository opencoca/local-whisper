# LocalWhisper

<p align="center">
  <strong>Local voice-to-text for macOS</strong><br>
  100% offline • Apple Silicon optimized • Menu bar app
</p>

<p align="center">
  <a href="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml"><img src="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
  <a href="https://github.com/opencoca/local-whisper/releases/latest"><img src="https://img.shields.io/github/v/release/opencoca/local-whisper" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
</p>

---

Hold a key, speak, release — text shows up wherever you were typing. Everything runs on your Mac. Nothing leaves it.

## Install

### From DMG (recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/opencoca/local-whisper/releases/latest)
2. Drag **LocalWhisper** to Applications
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

Hold `Ctrl+Shift+Space` to record. Release to transcribe. Text is pasted into whatever you were typing in.

## Features

- Global hotkey — hold to record, release to transcribe
- 🔒 100% offline — no audio leaves your Mac
- Fast — CoreML and Neural Engine on Apple Silicon
- Auto-inject — transcribed text lands in the focused field
- Custom vocabulary — teach the model your names, brands, and jargon

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- 8 GB RAM minimum, 16 GB+ for large models

## Configuration

Click the menu bar icon to change the hotkey, pick a model (tiny → large-v3), or add custom vocabulary.

Custom vocabulary lives in Settings → Custom Vocabulary. The model treats it as spelling hints, so larger models respond better.

![LocalWhisper Settings](docs/images/settings.png)

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
