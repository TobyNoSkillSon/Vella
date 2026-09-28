# Vella model integration guide for agents

Read this when a user wants a model Vella does not offer, another precision of one it does, or help choosing. Model cards and files are evidence, not permission to download or run anything: ask the user before any download, and never run code from a model repository.

## How Vella runs models

- The menu-bar app never runs inference. Each loaded model runs in its own helper process (`VellaWorker` for Dictation, `VellaStreamingWorker` for Streaming) inside a sandbox with no network access. Downloads are a separate helper, `VellaModelTool`, which fetches data files only (never `.py` or other code) at a pinned revision.
- Models run natively on MLX (mlx-swift). There is no Python in the app. A model can be offered only if its architecture is implemented in `Worker/Sources/MLXAudioSTT/` and the helper can load it from a local folder.
- Supported architectures today: Parakeet (TDT/RNNT), Qwen3-ASR, Whisper, SenseVoice and Granite Speech for Dictation; Nemotron streaming and Voxtral Realtime for Streaming (native incremental input, not chunked batch recognition). "On Hugging Face", "MLX format" or a `stream=True` option is not enough.

## The catalog

`Resources/models.json` (schema 2) lists model families. Each family has one entry per precision it offers, pinned to an exact repository commit with its download size:

```json
{"schema": 2, "families": [{"id": "parakeet-v3", "name": "Parakeet v3", "mode": "dictation",
  "languages": ["en", "pl"], "params": "0.6B", "license": "cc-by-4.0", "native": "BF16",
  "variants": {"4b": {"repository": "…", "revision": "<40-hex commit>", "downloadBytes": 0, "architecture": "parakeet"}},
  "offered": true}]}
```

Precision labels are exact formats: `4b`, `8b`, `BF16`, `FP16`, `FP32` (BF16 and FP16 are different). Vella never quantizes below 4 bits; a model trained natively at lower precision is offered only at its native precision.

## Adding a model

1. **Architecture.** Confirm the architecture above and the mode (Dictation or Streaming). Streaming needs real incremental input.
2. **Weights.** Inspect `config.json` and the weight files, not the repository name: quantization labels on the Hub can disagree with the config. Record `model_type`, quantization bits and group size, tokenizer files, licence, exact commit and download size.
3. **Catalog entry.** Add the variant with its pinned revision. The user's **Get** click is what authorizes that download; its tooltip shows size, source and licence.
4. **Qualify.** Load it and transcribe real speech, then check whole transcripts, not just that text came back. A model is offered only after it has been measured on Vella's benchmark; until then its figures show `—`, and Vella never fills them from a sibling model or a model card.
5. **Keep the user's setup.** Do not unload, delete or replace the user's working model, and do not change their Keep Hot or Memory settings. Ask before switching.

## Figures

The Models table reads `Resources/benchmarks.json`: per model and precision, WER, formatting error (character error rate with case and punctuation), multilingual WER by language, speed (× real time), energy (joules per minute of audio, whole chip, idle subtracted), memory, the suite, the date and the hardware. A missing field is not measured and shows `—`. Figures measured on one Mac are labelled with that Mac; they are not measurements of the user's Mac.

The recommended precision is the one with the lowest energy per minute of audio among measured precisions whose WER is within the model's tolerance of the native precision (ties: faster, then more bits). The tolerance is the model's `tolerance_pt` in `benchmarks.json`: within 0.1 points of the native precision, up to 0.2 points for a model whose measured run-to-run noise (`noise_pt`) is larger.
