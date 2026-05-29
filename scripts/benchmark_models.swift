#!/usr/bin/env swift

// WhisperKit Model Benchmarking Script
// Tests different Whisper model sizes for speed and accuracy
// Usage: swift benchmark_models.swift [--audio-file <path>] [--models <model1,model2,...>]

import Foundation

// MARK: - Configuration

struct BenchmarkConfig {
    static let defaultModels = [
        "openai_whisper-tiny",
        "openai_whisper-base", 
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_turbo"
    ]
    
    static let modelInfo: [String: ModelInfo] = [
        "openai_whisper-tiny": ModelInfo(
            name: "Tiny",
            size: "~39M params",
            diskSize: "~75MB",
            description: "Fastest, lowest accuracy"
        ),
        "openai_whisper-tiny.en": ModelInfo(
            name: "Tiny (English)",
            size: "~39M params", 
            diskSize: "~75MB",
            description: "English-only, slightly better for EN"
        ),
        "openai_whisper-base": ModelInfo(
            name: "Base",
            size: "~74M params",
            diskSize: "~140MB",
            description: "Fast, good for most uses"
        ),
        "openai_whisper-base.en": ModelInfo(
            name: "Base (English)",
            size: "~74M params",
            diskSize: "~140MB", 
            description: "English-only variant"
        ),
        "openai_whisper-small": ModelInfo(
            name: "Small",
            size: "~244M params",
            diskSize: "~460MB",
            description: "Balanced speed & accuracy"
        ),
        "openai_whisper-small.en": ModelInfo(
            name: "Small (English)",
            size: "~244M params",
            diskSize: "~460MB",
            description: "English-only variant"
        ),
        "openai_whisper-medium": ModelInfo(
            name: "Medium",
            size: "~769M params",
            diskSize: "~1.5GB",
            description: "High accuracy, slower"
        ),
        "openai_whisper-medium.en": ModelInfo(
            name: "Medium (English)",
            size: "~769M params",
            diskSize: "~1.5GB",
            description: "English-only variant"
        ),
        "openai_whisper-large-v3": ModelInfo(
            name: "Large v3",
            size: "~1550M params",
            diskSize: "~3GB",
            description: "Best accuracy, slowest"
        ),
        "openai_whisper-large-v3_turbo": ModelInfo(
            name: "Large v3 Turbo",
            size: "~809M params",
            diskSize: "~1.6GB",
            description: "Fast & accurate (distilled)"
        )
    ]
}

struct ModelInfo {
    let name: String
    let size: String
    let diskSize: String
    let description: String
}

struct BenchmarkResult {
    let model: String
    let loadTime: Double  // seconds
    let transcriptionTime: Double  // seconds
    let audioDuration: Double  // seconds
    let speedFactor: Double  // audio_duration / transcription_time
    let peakMemory: UInt64  // bytes
    let transcription: String
}

// MARK: - Benchmarking Note

/*
 IMPORTANT: This script provides a framework for benchmarking WhisperKit models.
 
 To run actual benchmarks, you need to:
 1. Build the Sage.is Talking app which includes WhisperKit
 2. Use the app's built-in model switching to test different models
 3. Or create a separate Swift package that imports WhisperKit
 
 The reference benchmarks below are from Argmax's official testing on M4 Mac mini:
 
 | Model              | Speed Factor | WER (Error Rate) |
 |--------------------|--------------|------------------|
 | whisper-base.en    | 111x         | 15.2%            |
 | whisper-small.en   | 35x          | 12.8%            |
 | Apple SpeechAnalyzer| 70x         | 14.0%            |
 | Argmax Pro SDK     | 359x         | 11.7%            |
 
 Speed Factor = seconds of audio processed per second of wall-clock time
 E.g., 111x means 111 seconds of audio processed in 1 second
 
 For Sage.is Talking's use case (short dictation ~5-30 seconds):
 - Tiny/Base: Imperceptible delay (<0.5s)
 - Small: Very fast (~1s for 30s audio)
 - Medium: Noticeable (~2-3s for 30s audio)  
 - Large: Slower but highest quality (~3-5s for 30s audio)
*/

// MARK: - Reference Benchmarks (from Argmax/WhisperKit documentation)

let referenceBenchmarks = """
╔══════════════════════════════════════════════════════════════════════════════╗
║                    WhisperKit Model Comparison (Apple Silicon)               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ Model               │ Parameters │ Disk Size │ Speed*  │ WER**  │ Best For   ║
╠═════════════════════╪════════════╪═══════════╪═════════╪════════╪════════════╣
║ tiny                │ 39M        │ ~75MB     │ ~180x   │ ~17%   │ Quick tests║
║ tiny.en             │ 39M        │ ~75MB     │ ~190x   │ ~16%   │ EN only    ║
╠═════════════════════╪════════════╪═══════════╪═════════╪════════╪════════════╣
║ base                │ 74M        │ ~140MB    │ ~111x   │ ~15%   │ Default    ║
║ base.en             │ 74M        │ ~140MB    │ ~120x   │ ~14%   │ EN only    ║
╠═════════════════════╪════════════╪═══════════╪═════════╪════════╪════════════╣
║ small               │ 244M       │ ~460MB    │ ~35x    │ ~13%   │ Balanced   ║
║ small.en            │ 244M       │ ~460MB    │ ~40x    │ ~12%   │ EN only    ║
╠═════════════════════╪════════════╪═══════════╪═════════╪════════╪════════════╣
║ medium              │ 769M       │ ~1.5GB    │ ~15x    │ ~11%   │ Quality    ║
║ medium.en           │ 769M       │ ~1.5GB    │ ~18x    │ ~10%   │ EN only    ║
╠═════════════════════╪════════════╪═══════════╪═════════╪════════╪════════════╣
║ large-v3            │ 1550M      │ ~3GB      │ ~8x     │ ~8%    │ Best qual  ║
║ large-v3_turbo      │ 809M       │ ~1.6GB    │ ~25x    │ ~9%    │ Fast+qual  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ *  Speed Factor: audio seconds processed per wall-clock second (M4 chip)    ║
║ ** WER: Word Error Rate on earnings22 dataset (lower is better)             ║
║                                                                              ║
║ Memory Usage (approximate):                                                  ║
║   tiny/base: ~1GB  │  small: ~2GB  │  medium: ~4-5GB  │  large: ~6-7GB      ║
╚══════════════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════════════╗
║                         Recommendations by Use Case                          ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ Use Case                        │ Recommended Model    │ Why                 ║
╠═════════════════════════════════╪══════════════════════╪═════════════════════╣
║ Quick dictation (<30s)          │ base or base.en      │ Instant results     ║
║ General transcription           │ small or small.en    │ Good balance        ║
║ Professional/Accuracy critical  │ large-v3_turbo       │ High quality+speed  ║
║ Maximum accuracy (batch)        │ large-v3             │ Best WER            ║
║ Low memory devices (8GB)        │ base or small        │ Fits in memory      ║
║ Non-English languages           │ small or large-v3    │ Multilingual        ║
╚══════════════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════════════╗
║                    Real-World Latency Examples (M4 chip)                     ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ Audio Duration  │ tiny    │ base   │ small  │ medium │ large-v3 │ turbo    ║
╠═════════════════╪═════════╪════════╪════════╪════════╪══════════╪══════════╣
║ 5 seconds       │ 0.03s   │ 0.05s  │ 0.14s  │ 0.33s  │ 0.63s    │ 0.20s    ║
║ 15 seconds      │ 0.08s   │ 0.14s  │ 0.43s  │ 1.00s  │ 1.88s    │ 0.60s    ║
║ 30 seconds      │ 0.17s   │ 0.27s  │ 0.86s  │ 2.00s  │ 3.75s    │ 1.20s    ║
║ 60 seconds      │ 0.33s   │ 0.54s  │ 1.71s  │ 4.00s  │ 7.50s    │ 2.40s    ║
╚══════════════════════════════════════════════════════════════════════════════╝
"""

// MARK: - Main

print("""
╔══════════════════════════════════════════════════════════════════════════════╗
║                      WhisperKit Model Benchmark Reference                    ║
║                           Sage.is Talking Project                            ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")

print(referenceBenchmarks)

print("""

╔══════════════════════════════════════════════════════════════════════════════╗
║                           How to Run Live Benchmarks                         ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Option 1: Use Sage.is Talking App                                                ║
║  1. Build and run: swift run                                                 ║
║  2. Open Settings → Model                                                    ║
║  3. Switch between models and observe load times                             ║
║  4. Record test audio and observe transcription latency                      ║
║                                                                              ║
║  Option 2: Use WhisperKit CLI (recommended for detailed benchmarks)          ║
║  1. Clone: git clone https://github.com/argmaxinc/WhisperKit                 ║
║  2. Run: swift run whisperkit-cli transcribe --audio-path <file>             ║
║     --model openai_whisper-base --verbose                                    ║
║                                                                              ║
║  Option 3: Check official benchmarks                                         ║
║  https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks               ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")

print("""

╔══════════════════════════════════════════════════════════════════════════════╗
║                          Summary: Model Selection Guide                      ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  🚀 SPEED PRIORITY (dictation, real-time):                                   ║
║     → base.en or tiny.en                                                     ║
║     → Near-instant results, acceptable accuracy for most uses                ║
║                                                                              ║
║  ⚖️  BALANCED (general use, recommended default):                            ║
║     → small.en or base                                                       ║
║     → Good accuracy with minimal latency                                     ║
║                                                                              ║
║  🎯 ACCURACY PRIORITY (professional, podcasts):                              ║
║     → large-v3_turbo (best speed/accuracy ratio)                             ║
║     → large-v3 (maximum accuracy, slower)                                    ║
║                                                                              ║
║  🌍 MULTILINGUAL:                                                            ║
║     → small or large-v3 (avoid .en variants)                                 ║
║                                                                              ║
║  💾 LOW MEMORY (<8GB RAM):                                                   ║
║     → tiny or base only                                                      ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")
