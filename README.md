# LocalWhisper

<p align="center">
  <strong>Local voice-to-text for macOS</strong><br>
  100% offline • Apple Silicon optimized • Menu bar app
</p>

<p align="center">
  <a href="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml"><img src="https://github.com/opencoca/local-whisper/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/opencoca/local-whisper/releases/latest"><img src="https://img.shields.io/github/v/release/opencoca/local-whisper" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
</p>

---

Hold a key, speak, release — text appears wherever you're typing. Everything runs on your Mac, powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit). No internet, no servers, no waiting.

## Install

### From DMG (recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/opencoca/local-whisper/releases/latest)
2. Drag **LocalWhisper** to Applications
3. Open it and grant **Microphone**, **Accessibility**, and **Input Monitoring** permissions

> First launch: right-click → Open to bypass the unidentified developer warning.

### From source

```bash
git clone https://github.com/opencoca/local-whisper.git
cd local-whisper
swift build && swift run
```

Grant **Microphone**, **Accessibility**, and **Input Monitoring** permissions when prompted.

## Use

Hold `Ctrl+Shift+Space` to record. Release to transcribe. Text is pasted into your focused app.

## Features

- **Global hotkey** — hold to record, release to transcribe
- 🔒 **100% offline** — no audio ever leaves your Mac
- **Fast** — CoreML and Neural Engine on Apple Silicon
- **Auto-inject** — transcribed text appears in whatever you're typing into
- **Custom vocabulary** — add names, brands, and terms the model should know

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)
- 8 GB RAM minimum (16 GB+ for large models)

## Configuration

Click the menu bar icon to change the hotkey, select a model (tiny → large-v3), or manage custom vocabulary.

Add product names, technical terms, and proper nouns in Settings → Custom Vocabulary. Works best with `small` or larger models — vocabulary provides spelling hints, not instructions.

![LocalWhisper Settings](docs/images/settings.png)

## Documentation

- [Model Guide](docs/models.md) — comparison, benchmarks, recommendations
- [Architecture](docs/architecture.md) — structure and development guide

## Privacy

All transcription runs locally on your Mac. No audio is sent over the network. No analytics, no telemetry.

## License

- **Pre-fork code** — MIT License, Copyright © 2024 LocalWhisper. See [LICENSE-MIT](LICENSE-MIT).
- **Startr LLC contributions** — AGPL-3.0, Copyright © 2026 Startr LLC. See [LICENSE](LICENSE).

The combined work is distributed under AGPL-3.0. If you modify and distribute LocalWhisper — or run it as a network service — you must release those changes under AGPL-3.0 with source included.

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Swift Whisper with CoreML
- [OpenAI Whisper](https://github.com/openai/whisper) — original model
