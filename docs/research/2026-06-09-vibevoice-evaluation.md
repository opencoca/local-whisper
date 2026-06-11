# VibeVoice evaluation

*2026-06-09 — evaluated Microsoft's VibeVoice voice-AI family against Sage.is Talking's needs. Verdict: don't adopt as an engine; salvage the diarization idea for meetings (backlogged separately).*

## What it is

[microsoft/VibeVoice](https://github.com/microsoft/VibeVoice) is an open-source (MIT) voice-AI family. Three models:

- **VibeVoice-TTS-1.5B** — long-form, up to ~90 min, up to 4 speakers. The flagship.
- **VibeVoice-ASR-7B** — 60-min single-pass recognition, 50+ languages, speaker diarization, timestamps, hotword support.
- **VibeVoice-Realtime-0.5B** — streaming TTS, ~300 ms first-audio latency, single speaker, ~10 min cap.

Architecture: continuous speech tokenizers at a 7.5 Hz frame rate (the trick that lets long-form fit), a Qwen2.5-1.5B LLM backbone for textual context, and a diffusion head for acoustic detail ("next-token diffusion"). Genuinely frontier; the quality reputation is real.

## Why we are not adopting it as an engine

1. **Governance risk.** Microsoft pulled the flagship TTS code from the repo on 5 Sept 2025, ~10 days after release, after it was used for deepfakes. Weights remain on Hugging Face, but the official inference code is gone. A repo that yanked its main model under pressure is not a dependency to put under a privacy-first app.
2. **License/policy collision.** MIT on the code, but the model card says research-and-development only, not for commercial use without further testing. The realtime model embeds a mandatory audible disclaimer plus an imperceptible watermark, and the usage policy forbids impersonation and real-time voice conversion. Shipping audio that announces itself as synthetic does not sit cleanly inside an AGPL product also headed for the Mac App Store.
3. **Wrong runtime for an on-device Mac app.** PyTorch + `transformers`, CUDA-first. No official CoreML, ONNX, GGUF, or Apple Silicon support (community MPS forks only). Even the 0.5B realtime model needs the full Python inference stack and is single-speaker, so it cannot do voice cloning. Built for a GPU server, not the Neural Engine. Kokoro (~82M, CoreML) remains the right call for our TTS lane.

## What is worth keeping

**Speaker diarization for meetings.** VibeVoice-ASR-7B does 60-min single-pass recognition with diarization + timestamps. We cannot ship that model, but the capability — labelling who said what across a long multi-speaker recording — is the highest-value idea here. The 90-min interview already in Done proves our long-form transcription works; diarization turns a wall of undifferentiated text into an attributable transcript, which is exactly what meeting use needs. Backlogged as its own card in [TODO.md](../../TODO.md); the on-device path (WhisperKit has no native diarization) is the open question to research there.

**The misuse story as design input.** VibeVoice is the worked example of releasing a powerful open voice model with no consent gate, then retrofitting watermarks and pulling code under pressure. When the Chatterbox voice-cloning lane (v3) comes up, design consent + provenance in from day one rather than after.

## Sources

- [microsoft/VibeVoice](https://github.com/microsoft/VibeVoice)
- [VibeVoice-Realtime-0.5B model card](https://huggingface.co/microsoft/VibeVoice-Realtime-0.5B)
- [VibeVoice-1.5B model card](https://huggingface.co/microsoft/VibeVoice-1.5B)
- [Project page](https://microsoft.github.io/VibeVoice/)
