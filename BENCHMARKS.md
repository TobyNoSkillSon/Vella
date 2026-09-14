# Accumulated model benchmarks

One table of the **37 published reference runs plus one qualification control rerun**, as of 14 September 2026. Each model name links to its source JSON. The same model can appear more than once because it was tested on different suites or through different inference paths. These are measured runs, not 38 different models.

**Hardware:** Apple M5 Max, 128 GiB system RAM. **Runtime:** MLX Audio 0.5.1 / MLX 0.32.2 on macOS 26.6. Every reference run uses two timing passes per clip. This document collects existing results; it does not introduce new inference runs.

## Which rows to compare

- **A — Current formatted suite:** `english-formatted-20m-v1`, 144 clips, 34 speakers, 1,215.435 seconds (20m 15s). Use these rows for current model comparisons. Batch and native Streaming share the audio, references and scorers, but use different inference paths and timing scopes.
- **B — Historical 20-minute suite:** `english-20m-v1`, 141 clips, 1,200.580 seconds. Earlier LibriSpeech test-clean measurements, retained for history. They are not the same corpus/scoring setup as A.
- **C — Historical mini suite:** `english-mini-v1`, five clips from one speaker, 62.455 seconds. Smoke-test results, not a broad accuracy ranking.

The table groups current batch results, the control rerun, current Streaming, then historical suites. Current groups sort by full-text error; historical groups sort by word error. **Do not average the suites together or read the whole table as one ranking.**

## All measurements

| Set | Mode | Model / precision · source | Word error ↓ | Text error ↓ | Punctuation F1 ↑ | Case accuracy ↑ | Speed ↑ | Compute seconds | MLX peak GB | Memory basis | Measured UTC |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| A | Batch | [Parakeet v3 4-bit](Resources/ReferenceResults/formatted-M5Max-parakeet-tdt-0.6b-v3-mlx-4bit.json) | 1.54% | 1.77% | 75.43% | 98.06% | 233.71× | 5.20 | 1.34 | Warm / separate | 2026-09-12 |
| A | Batch | [Parakeet v3 8-bit](Resources/ReferenceResults/formatted-M5Max-parakeet-tdt-0.6b-v3-mlx-8bit.json) | 1.60% | 1.85% | 75.31% | 97.77% | 237.42× | 5.12 | 1.61 | Warm / separate | 2026-09-12 |
| A | Batch | [Qwen3 ASR 0.6B 4-bit](Resources/ReferenceResults/formatted-M5Max-Qwen3-ASR-0.6B-4bit.json) | 1.54% | 2.07% | 72.68% | 97.55% | 88.57× | 13.72 | 1.93 | Warm / separate | 2026-09-13 |
| A | Batch | [Qwen3 ASR 1.7B BF16](Resources/ReferenceResults/formatted-M5Max-Qwen3-ASR-1.7B-bf16.json) | 1.41% | 2.08% | 75.23% | 97.39% | 30.52× | 39.83 | 5.50 | Warm / separate | 2026-09-12 |
| A | Batch | [Qwen3 ASR 1.7B 4-bit](Resources/ReferenceResults/formatted-M5Max-Qwen3-ASR-1.7B-4bit.json) | 1.51% | 2.12% | 75.00% | 97.36% | 59.50× | 20.43 | 3.03 | Warm / separate | 2026-09-12 |
| A | Batch | [Qwen3 ASR 1.7B 8-bit](Resources/ReferenceResults/formatted-M5Max-Qwen3-ASR-1.7B-8bit.json) | 1.57% | 2.14% | 75.50% | 97.42% | 44.53× | 27.30 | 3.89 | Warm / separate | 2026-09-12 |
| A | Batch | [Nemotron 3.5 ASR 0.6B 8-bit](Resources/ReferenceResults/formatted-M5Max-nemotron-3.5-asr-streaming-0.6b-8bit.json) | 2.64% | 2.53% | 68.18% | 97.75% | 52.92× | 22.97 | 0.99 | Warm / separate | 2026-09-13 |
| A | Batch | [Voxtral Mini Realtime 4B 4-bit](Resources/ReferenceResults/formatted-M5Max-Voxtral-Mini-4B-Realtime-2602-4bit.json) | 2.26% | 2.57% | 77.24% | 97.88% | 5.05× | 240.67 | 5.94 | Warm / separate | 2026-09-13 |
| A | Batch | [Whisper large-v3 8-bit](Resources/ReferenceResults/formatted-M5Max-whisper-large-v3-8bit.json) | 2.60% | 4.50% | 46.56% | 94.74% | 20.98× | 57.93 | 2.52 | Warm / separate | 2026-09-12 |
| A | Batch | [Granite 4.0 1B 4-bit](Resources/ReferenceResults/formatted-M5Max-granite-4.0-1b-speech-4bit.json) | 1.29% | 4.61% | 0.93% | 90.91% | 44.14× | 27.54 | 7.64 | Warm / separate | 2026-09-12 |
| A | Batch | [Granite 4.0 1B 8-bit](Resources/ReferenceResults/formatted-M5Max-granite-4.0-1b-speech-8bit.json) | 1.19% | 4.61% | 0.92% | 90.96% | 37.36× | 32.53 | 8.56 | Warm / separate | 2026-09-12 |
| A | Batch | [Whisper large-v3 FP16](Resources/ReferenceResults/formatted-M5Max-whisper-large-v3-asr-fp16.json) | 2.82% | 4.76% | 46.08% | 94.67% | 19.69× | 61.71 | 4.03 | Warm / separate | 2026-09-12 |
| A | Batch | [SenseVoice FP32](Resources/ReferenceResults/formatted-M5Max-SenseVoiceSmall.json) | 2.45% | 5.05% | 0.00% | 91.20% | 631.61× | 1.92 | 1.79 | Warm / separate | 2026-09-12 |
| A | Batch | [SenseVoice 4-bit](Resources/ReferenceResults/formatted-M5Max-SenseVoiceSmall-4bit.json) | 3.45% | 5.40% | 0.00% | 91.44% | 582.30× | 2.09 | 0.88 | Warm / separate | 2026-09-12 |
| A | Batch | [Granite Speech 5.0 TurboCTC 470M FP16](Resources/ReferenceResults/formatted-M5Max-granite-speech-5.0-470m-turboctc-mlx-fp16.json) | 3.70% | 5.87% | 0.00% | 90.96% | 654.00× | 1.86 | 1.59 | Warm / separate | 2026-09-13 |
| A | Batch | [Whisper large-v3 4-bit](Resources/ReferenceResults/formatted-M5Max-whisper-large-v3-asr-4bit.json) | 4.14% | 6.30% | 48.50% | 95.09% | 22.17× | 54.81 | 1.75 | Warm / separate | 2026-09-12 |
| A | Batch control | [Parakeet v3 4-bit — rerun](Resources/Benchmarks/qualification-2026-09-12.json) | 1.54% | 1.77% | — | — | 228.48× | — | — | Not reported | 2026-09-12 |
| A | Streaming | [Nemotron 3.5 ASR 0.6B 8-bit](Resources/ReferenceResults/formatted-streaming-M5Max-nemotron-3.5-asr-streaming-0.6b-8bit.json) | 2.95% | 2.66% | 64.75% | 98.03% | 15.33× | 79.28 | 0.98 | Warm / separate | 2026-09-13 |
| A | Streaming | [Nemotron 3.5 ASR 0.6B BF16](Resources/ReferenceResults/formatted-streaming-M5Max-nemotron-3.5-asr-streaming-0.6b-bf16.json) | 2.86% | 2.66% | 64.96% | 97.90% | 8.06× | 150.87 | 2.22 | Warm / separate | 2026-09-13 |
| A | Streaming | [Voxtral Mini Realtime 4B 4-bit](Resources/ReferenceResults/formatted-streaming-M5Max-Voxtral-Mini-4B-Realtime-2602-4bit.json) | 2.35% | 2.71% | 76.34% | 97.56% | 1.19× | 1024.09 | 5.56 | Warm / timing | 2026-09-13 |
| B | Batch | [Granite 4.0 1B 8-bit](Resources/ReferenceResults/english-20m-M5Max-granite-4.0-1b-speech-8bit.json) | 1.34% | — | — | — | 37.27× | 32.21 | 8.56 | Legacy peak | 2026-09-12 |
| B | Batch | [Granite 4.0 1B 4-bit](Resources/ReferenceResults/english-20m-M5Max-granite-4.0-1b-speech-4bit.json) | 1.40% | — | — | — | 43.78× | 27.42 | 7.64 | Legacy peak | 2026-09-12 |
| B | Batch | [Qwen3 ASR 1.7B BF16](Resources/ReferenceResults/english-20m-M5Max-Qwen3-ASR-1.7B-bf16.json) | 1.59% | — | — | — | 28.18× | 42.61 | 5.50 | Legacy peak | 2026-09-12 |
| B | Batch | [Qwen3 ASR 1.7B 4-bit](Resources/ReferenceResults/english-20m-M5Max-Qwen3-ASR-1.7B-4bit.json) | 1.62% | — | — | — | 54.49× | 22.03 | 3.03 | Legacy peak | 2026-09-12 |
| B | Batch | [Parakeet v3 4-bit](Resources/ReferenceResults/english-20m-M5Max-parakeet-tdt-0.6b-v3-mlx-4bit.json) | 1.66% | — | — | — | 229.64× | 5.23 | 1.34 | Legacy peak | 2026-09-12 |
| B | Batch | [Parakeet v3 8-bit](Resources/ReferenceResults/english-20m-M5Max-parakeet-tdt-0.6b-v3-mlx-8bit.json) | 1.69% | — | — | — | 225.27× | 5.33 | 1.61 | Legacy peak | 2026-09-12 |
| B | Batch | [Qwen3 ASR 1.7B 8-bit](Resources/ReferenceResults/english-20m-M5Max-Qwen3-ASR-1.7B-8bit.json) | 1.75% | — | — | — | 41.68× | 28.81 | 3.89 | Legacy peak | 2026-09-12 |
| B | Batch | [SenseVoice FP32](Resources/ReferenceResults/english-20m-M5Max-SenseVoiceSmall.json) | 2.58% | — | — | — | 641.93× | 1.87 | 1.79 | Legacy peak | 2026-09-12 |
| B | Batch | [Whisper large-v3 4-bit](Resources/ReferenceResults/english-20m-M5Max-whisper-large-v3-asr-4bit.json) | 3.06% | — | — | — | 23.38× | 51.36 | 1.75 | Legacy peak | 2026-09-12 |
| B | Batch | [SenseVoice 4-bit](Resources/ReferenceResults/english-20m-M5Max-SenseVoiceSmall-4bit.json) | 3.66% | — | — | — | 592.93× | 2.02 | 0.89 | Legacy peak | 2026-09-12 |
| B | Batch | [Whisper large-v3 FP16](Resources/ReferenceResults/english-20m-M5Max-whisper-large-v3-asr-fp16.json) | 5.38% | — | — | — | 17.68× | 67.89 | 4.03 | Legacy peak | 2026-09-12 |
| B | Batch | [Whisper large-v3 8-bit](Resources/ReferenceResults/english-20m-M5Max-whisper-large-v3-8bit.json) | 6.66% | — | — | — | 19.69× | 60.98 | 2.52 | Legacy peak | 2026-09-12 |
| C | Batch | [Qwen3 ASR 1.7B 8-bit](Resources/ReferenceResults/Qwen3-ASR-1.7B-8bit.json) | 3.31% | — | — | — | 52.35× | 1.19 | 3.88 | Legacy peak | 2026-09-12 |
| C | Batch | [Qwen3 ASR 1.7B BF16](Resources/ReferenceResults/qwen.json) | 3.31% | — | — | — | 34.55× | 1.81 | 5.49 | Legacy peak | 2026-09-12 |
| C | Batch | [Qwen3 ASR 1.7B 4-bit](Resources/ReferenceResults/qwen4.json) | 4.64% | — | — | — | 69.44× | 0.90 | 3.02 | Legacy peak | 2026-09-12 |
| C | Batch | [Whisper large-v3 8-bit](Resources/ReferenceResults/whisper-large-v3-8bit.json) | 5.30% | — | — | — | 28.69× | 2.18 | 2.53 | Legacy peak | 2026-09-12 |
| C | Batch | [Whisper large-v3 FP16](Resources/ReferenceResults/whisper-large-v3-asr-fp16.json) | 5.30% | — | — | — | 25.54× | 2.45 | 4.03 | Legacy peak | 2026-09-12 |
| C | Batch | [Whisper large-v3 locally quantized 8-bit](Resources/ReferenceResults/whisper.json) | 5.30% | — | — | — | 28.04× | 2.23 | 2.53 | Legacy peak | 2026-09-12 |

## Reading the columns

- **Word error (WER):** wrong, missing and added words relative to the reference. Ignores punctuation and case. Lower is better. Historical suites retain their original scoring; they have not been relabeled as current scores.
- **Text error (CER):** character edit distance with punctuation and capitalization retained. Lower is better. It measures agreement with one written reference, not the only correct way to punctuate speech.
- **Punctuation F1 and case accuracy:** higher is better, but these are conditional on eligible aligned words/boundaries. Coverage counts and fractions are in each current row's `formatting` object. They are not whole-transcript correctness scores. Quote-specific metrics are left in the raw records: only three reference clips contain quotation marks, too few for a useful headline comparison.
- **Speed:** audio duration divided by warm compute time; 60× means roughly one second of inference per minute of audio. **Compute seconds** is the recorded aggregate of per-clip median timings, not two corpus durations added together. Loading and user-facing insertion time are not included. The control summary reports speed but not a separate compute-time or memory value; those cells remain blank.
- **MLX peak GB:** decimal gigabytes (1 GB = 1,000,000,000 bytes) allocated through MLX. This is **not total app RAM or system memory**, and is not the machine's 128 GiB capacity.
- **Warm / separate:** post-warmup MLX high-water mark from a separate memory run. For current batch rows, the attached `runtimeMemoryMeasurement` supplies the value; Streaming uses `memoryMeasurement`.
- **Warm / timing:** post-warmup MLX peak recorded during the completed timing run. This applies to Voxtral Streaming; it is not a separate memory profile.
- **Legacy peak:** the older run's `peakMLXBytes`. Those records do not document the newer post-warmup reset protocol, so these values must not be presented as equivalent warm-memory profiles.
- **—:** no corresponding value in that source record, not zero and not a value borrowed from another run.

## Streaming and other limits

Native Streaming rows use Vella's actual incremental worker, 100-ms input packets, and normal gate/partial/final-flush behavior. Their speed is accelerated compute throughput, excluding loading, IPC and inter-clip reset. Batch timings include their own per-clip setup. Neither number is measured microphone-to-word latency. Nemotron's 320-ms context and Voxtral's configured 480-ms delay are settings, not observed latency results.

These are clean English reading clips. They do not establish conversational, noisy-room or multilingual accuracy, physical day-long microphone endurance, or error-free transcription. Some recordings still remain unresolved under Vella's conservative recovery checks. Model accuracy is not an end-to-end app reliability score.

All completed reference JSON files are represented once, plus the published control summary. Separate memory profiles are incorporated as memory evidence, not counted again as independent accuracy runs. Private recording regressions, installation checks and interrupted experiments are not comparable model benchmarks and are not included. VibeVoice and Moonshine were screened but not benchmark-qualified in the pinned runtime. Granite Speech 5.0 TurboCTC Q8 failed compatibility; no score is invented for it. See the [qualification record](Resources/Benchmarks/qualification-2026-09-12.json).

Being measured does not mean a model is available in Vella's current menu. Consult the [Dictation catalog](Resources/models.json), [Streaming catalog](Resources/streaming-models.json), and [additional batch candidates](Resources/Benchmarks/additional-models.json).

## Source data and documentation

The JSON files are authoritative. They retain exact precision, model fingerprints, measurement dates, parameters, per-clip results, and available scorer/worker hashes. Raw process-memory counters are also retained there; in particular, Streaming benchmark RSS includes corpus buffers and event evidence, so it is not a clean total-app memory comparison.

- [Reference runs](Resources/ReferenceResults/) · [Memory profiles](Resources/MemoryResults/)
- [Current scoring policy and hashes](Resources/benchmark-policy.json)
- Suite manifests: [A](Resources/Benchmarks/english-formatted-20m-v1/manifest.json) · [B](Resources/Benchmarks/english-20m-v1/manifest.json) · [C](Resources/Benchmarks/english-mini-v1/manifest.json)
- [Install and use Vella](README.md) · [Model integration guide](Resources/AGENT_GUIDE.md)
- [License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

When publishing another benchmark, add its row here from the preserved result and retain its suite, inference mode and memory provenance. Do not overwrite historical rows with newer scores or average repeated suites into one number.
