# Vella model integration guide for agents

Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far.

Read this when a user wants a model Vella does not offer, another precision of one it does, or help choosing. Model cards and files are evidence, not permission to download or run anything: ask the user before any download, and never run code from a model repository.

## How Vella runs models

- The menu-bar app never runs inference. Each loaded model runs in its own helper process (`VellaWorker` for Dictation, `VellaStreamingWorker` for Streaming) inside a sandbox with no network access. The app itself downloads a model: data files only (never `.py` or other code), at the revision the catalog pins, each file checked against the size and hash recorded for that revision.
- Models run natively on MLX (mlx-swift). There is no Python in the app. A model can be offered only if its architecture is implemented in `Worker/Sources/MLXAudioSTT/` and the helper can load it from a local folder.
- Vella loads only models in its catalog (below); a folder prepared some other way is not accepted.
- Supported architectures today: Parakeet (TDT), Qwen3-ASR and Whisper for Dictation; Nemotron streaming for Streaming (native incremental input, not chunked batch recognition). "On Hugging Face", "MLX format" or a `stream=True` option is not enough.

## The catalog

<!-- CREDITS_START -->
Parakeet v3 Ultra: Moondream's post-training of NVIDIA Parakeet v3 for dictation in 25 European languages; none from outside Europe. CC BY 4.0; MLX conversion: `selcukkubur/parakeet-ultra-mlx`. Model publishers, source checkpoints, MLX converters and licences: `THIRD_PARTY_NOTICES.md`.
<!-- CREDITS_END -->

`Resources/models.json` (schema 2) lists model families. A family offers up to three tiers: **16** (the checkpoint's own bf16 or fp16), **8** (affine 8-bit, group 64) and **4** (affine 4-bit, group 64). fp32 is never a tier. Only the 16-bit checkpoint is downloaded, pinned to an exact commit with its size; an fp32-only model downloads its fp32 source and Vella converts it once to bf16 at Get, keeping only the bf16 weights. 8 and 4 are made on the Mac from the 16-bit weights (`mx.quantize`, group 64), never from a quantized source:

```json
{"schema": 2, "families": [{"id": "parakeet-v3-ultra", "name": "Parakeet v3 Ultra", "mode": "dictation",
  "languages": ["en", "pl"], "params": "0.6B", "license": "cc-by-4.0", "native": "BF16",
  "native_dtype": "bfloat16", "tiers_offered": ["16", "8", "4"],
  "download": {"repo": "…", "revision": "<40-hex commit>", "bytes": 1254840214, "convert_to": ["8", "4"]},
  "variants": {"BF16": {"id": "…", "repository": "…", "revision": "<40-hex commit>", "downloadBytes": 1254840214, "architecture": "parakeet"},
               "8b": {"id": "…", "derivedFrom": "BF16", "bits": 8, "groupSize": 64, "architecture": "parakeet"}},
  "offered": true}]}
```

`tiers_offered` lists the tiers the app offers: a tier is left out only when it breaks on Vella's benchmark (lost clips, empty or invalid output, a word error rate 5 points or more above the 16-bit one, or any one language 10 points or more above it). Each tier runs on **Standard** (stock MLX) or **Optimized** (Vella's self-tested kernels), and Optimized is **Exact** (exact-only components that must match Standard on the load-time self-test; full-suite figures can differ slightly) or **Fast** (adds kernels that passed the noise gate). The Models table shows both paths as two **Precision** rows of three cells named by the format that runs (`bf16`/`fp16`, `int8`, `int4`), Optimized (a bolt) above Standard (the MLX logo), with a Fast/Exact switch as tall as both rows that sets the Optimized row (Exact lists only the tiers with an `optimized_exact` recipe); a cell that cannot run is greyed in place with its reason, and every other cell can be chosen and shows its own figures, with the difference from Standard 16 beneath. The API reports what runs as `selection` and still accepts `standard`.

## Adding a model

For a checkpoint of an existing architecture, reuse its runtime: catalog entry plus a model folder and a fixture. A new architecture needs engineering against `SpeechModelRuntime`, registration, loading/decoding and a fixture test. The recipe is in https://github.com/TobyNoSkillSon/Vella/blob/main/CONTRIBUTING.md#adding-a-model.

1. **Architecture.** Confirm the architecture above and the mode (Dictation or Streaming). Streaming needs real incremental input.
2. **Weights.** Inspect `config.json` and the weight files, not the repository name: quantization labels on the Hub can disagree with the config. Record `model_type`, quantization bits and group size, tokenizer files, licence, exact commit and download size.
3. **Catalog entry.** Add the family with its pinned 16-bit checkpoint (`download`, the 16-bit variant) and the 8/4 variants as local derivations; list in `tiers_offered` only the tiers that pass the benchmark. A user's **Download** confirmation in the table, or an authenticated `vella get ID --yes` after consent to the pinned source/size, authorizes that one download.
4. **Qualify.** Load it and transcribe real speech, then check whole transcripts, not just that text came back. A model is offered only after it has been measured on Vella's benchmark; until then its figures show `—`, and Vella never fills them from a sibling model or a model card.
5. **Keep the user's setup.** Do not unload, delete or replace the user's working model, and do not change their Keep Hot or Memory settings. Ask before switching.

## Figures

The Models table reads `Resources/benchmarks.json`: per model, per tier (`16`, `8`, `4`), per path (`standard`, `optimized_exact`, `optimized_fast`), the measured WER, formatting error (character error rate with case and punctuation), multilingual WER by language, speed (× real time), energy (joules per minute of audio, whole chip, idle subtracted), peak RAM during transcription, the suite, the date and the hardware, plus the recipe that ran. A missing field is not measured and shows `—`. Figures measured on one Mac are labelled with that Mac; they are not measurements of the user's Mac.

Each cell’s `gate.presence` (`offered` and short `reasons`) determines whether that cell is offered; only a cell with no gate inherits the tier’s `presence`. A gate without a readable presence verdict is not offered. Each tier also carries `presence`: a tier is absent only when it breaks (lost clips, empty or invalid output, a crash, a word error rate at least 5 points above the 16-bit tier's, or any one language at least 10 points above it). A tier that is merely worse is offered and its loss is in its numbers. `models.json`'s `tiers_offered` matches `presence`. There is no recommended cell: the user chooses the precision and Exact or Fast; a model never chosen loads on the first offered, measured cell, preferring Optimized 16 · Fast; a saved cell that is no longer offered resolves to an offered cell and the launch migration discloses the change. A model's languages are in its name's tooltip (its `summary` in `models.json`). While `benchmarks.json` has `figures_pending: true` (its figures predate the build that ships) the table shows no figure and no difference; the next measurement rewrites the file with `figures_pending: false`.

## Recipe defaults

Fast enables every kept lever for the selected checkpoint; Exact enables only exact kept levers; Standard enables none. Parakeet v3/Ultra 8/4 Fast use native INT8/INT4. Ultra BF16/8/4 Fast and Exact use tail-block sizing (v3 does not). Nemotron BF16/8/4 Fast and Exact keep the buffer cache; BF16 Fast also batches the joint projection. Rejected levers remain off. Lab overrides `=1`/`=0` enable/disable a lever without changing the recipe safety boundary.
