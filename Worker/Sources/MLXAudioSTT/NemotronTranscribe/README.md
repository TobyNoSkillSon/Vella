# Nemotron 3.5 Transcribe

This folder is the runtime of Nemotron 3.5 Transcribe 30B-A4B, a Dictation model: it transcribes a whole recording at
a time and is offered beside Parakeet v3 Ultra for Macs with enough memory. It is offline: text appears only after a
whole chunk is encoded, so it is never the Streaming model and never the first-run default. The catalog entry is in
`Resources/models.json`, the descriptor in `Sources/VellaCore/Models/NemotronTranscribe/`.

## What it is

| | |
|---|---|
| Catalog id | `nemotron-3.5-transcribe` |
| Publisher, licence | NVIDIA (2026), OpenMDW-1.1. Every tier's folder carries `LICENSE`, `THIRD_PARTY_NOTICES.md` and `licenses/`, and so must every redistribution |
| Source checkpoint | `nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B` (BF16, SHA-256 `03142dde…acff2`) |
| Parameters | 30B in total, about 4B active per token: a 52-layer Nemotron-H decoder (Mamba-2, attention and 128-expert MoE layers, 6 experts per token) fed by a feature-stacking RoPE Transformer speech encoder (32 layers) and a Sortformer speaker encoder (31 layers) |

The port follows mlx-audio at commit `92decb7` (`mlx_audio/stt/models/nemotron_transcribe`, MIT), which follows NVIDIA
NeMo Speech (Apache-2.0):

- `NemotronTranscribeDecoder.swift`: the Nemotron-H decoder, including the vendored mlx-lm SSM kernels, and the MTP head.
  The SSM scan, its skip connection and the gated norm run in FP32, as NeMo keeps A_log, D, dt_bias and the state.
  The MoE router is FP32 as well.
- `NemotronTranscribePerception.swift`: the log-mels (using the checkpoint's own filter bank and window), both encoders,
  the speaker model's FIFO and AOSC speaker cache over 40 s windows, and the sinusoidal speaker fusion.
- `NemotronTranscribeModel.swift`: loading, the prompt, greedy decoding, the MTP chain, chunking and the vocabulary guard.
- `NemotronTranscribeText.swift`: the MLX-free parts, covered by `Worker/Tests/VellaWorkerTests/NemotronTranscribeTests.swift`.

## Tiers

Each tier is its own download; nothing is derived on the Mac.

- **16**: NVIDIA's BF16 original in NeMo layout, one `model.safetensors`. Its keys are mapped at load, and the MTP and
  CTC-timestamp heads are not loaded, so it decodes plain greedy.
- **8**: routed and shared experts, Mamba projections and attention are int8 affine, group 64.
- **4**: routed experts are int4 group 64, everything a token always passes through is int8.

In tiers 8 and 4, embeddings, the output head, norms, the router, Mamba A/D/dt and both encoders stay as shipped.
Both tiers carry `extras/mtp.safetensors`.

Accuracy against BF16, layer-streamed and teacher-forced (4 clips, 512 tokens; measured 28 Oct 2026 by the
conversion): int8 has mean KL 0.0107 and top-1 98.2 %; int4 has KL 0.0144 and top-1 97.9 %.

## Decoding

- **Prompt.** Dictation always uses the checkpoint's plain ASR prompt, in the `nemotron3p5` chat format with thinking
  off. The speaker-attributed, rich-transcription and translation prompts are never used. Any markup that still
  appears is removed and the words between tags are kept: `<spk:N>`, `<ev:…>`, `<sty:…>` and `<think>` blocks.
- **Vocabulary.** The user's `vocabulary.json` (`docs/vocabulary.md`) adds `Contextual vocabulary: a, b, c` to the
  prompt. Only the plain `words` go in, never Parakeet's acoustic entries or variants. The hint can make words up: on
  Toby's speech, a 17-word list made the model append "Poznań", which was never spoken. When the last sentence
  consists only of list words, the same audio embeddings are decoded once more without the list, and the sentence is
  dropped if that transcript has fewer sentences. The list can also bend spellings ("usunąć" became "usunąń" once);
  nothing here undoes that.
- **Chunks.** The app hands the worker segments cut at pauses: at most 30 s, with this model preferring a cut after
  20 s (its descriptor), like Whisper. Long files are segmented the same way, and a worker request is at most 2 MB of
  WAV, about 65 s. The model's own two-minute limit is therefore always met. `NemotronTranscribeChunking` still cuts
  anything longer at the quietest 100 ms in the last 20 s before 120 s, as a backstop. The two-minute limit exists
  because on a 5-minute recording, small numeric changes flipped punctuation and one run dropped its last two
  sentences.
- **Warm-up.** Loading decodes 2 s of faint noise. Without it, the first request paid about 11 s of one-time kernel
  preparation: a 25 s segment took 12.2 s cold and 0.75 s warm. With it, load took 8.8 s and the first segment 0.78 s
  (release worker, int4, M5 Max, 28 Oct).
- **MTP self-speculation.** In tiers 8 and 4, the MTP head drafts 4 chained tokens and the main model verifies them in
  one pass, with one host sync per pass. Mamba states are restored and attention caches trimmed when a draft is
  rejected. `VELLA_NEMOTRON_TRANSCRIBE_MTP=0` selects plain greedy for lab A/B work.
- **No self-test child.** `hasFastPath` is false: qualifying would load a second 21–68 GB copy in a child process. The
  MTP chain is part of decoding, verified token by token by the main model, not a separately qualified kernel.

## Parity (opt-in test, int4, M5 Max 128 GB, macOS 27.0.1, 28 Oct 2026)

`parityWithPythonReference` in `NemotronTranscribeTests.swift` compares the token IDs of this port with mlx-audio
`92decb7` (MLX 0.32.4, `generate_step` with 512-token prefill blocks, and the research runner's `generate_chain`, depth 4).
It uses two FLEURS Polish clips, 15 s and 60 s; the 60 s clip crosses the 40 s speaker window. Each clip runs with no
list and with a three-word list. The reference script and both result files are in `lab/models/NemotronTranscribe/`.

| | stock vs mlx-audio stock | MTP vs mlx-audio chain | Swift MTP vs Swift stock |
|---|---|---|---|
| 15 s, no list | identical (43 tokens) | identical | identical |
| 15 s, list | identical | identical | identical |
| 60 s, no list | identical (180 tokens) | first 95 tokens identical | same words |
| 60 s, list | 4 words differ, near ties ("Czoło"/"Czoł") | first 2 tokens identical | 2 words differ |

mlx-audio's own chain also differs from its own stock on both 60 s runs. The differences are near-tie choices,
noise-level under the family quality-gate rule. Decode time in the same run, from the debug test build with MLX in
release: 15 s clip 0.96 s stock vs 0.46 s MTP; 60 s clip 3.5–4.3 s stock vs 1.9–2.5 s MTP. Peak MLX memory was 23.1 GB.
These are screening numbers, not the release measurement.

## Known limits

- Faint background voices are skipped, which suits dictation: on Toby's 36 s call recording, a distant second voice
  25–27 dB below his level was left out. Very quiet trailing words of the speaker can be dropped too.
- The BF16 and int8 tiers have not been run end to end yet; their memory figures are estimates.
- The CTC word-timestamp head is not used, so there are no word timings.

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Measured — on —. English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately. Accuracy: —; speed, energy and peak RAM: —.

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor and every kept module stays at the source dtype.

#### Nemotron 3.5 Transcribe (`nemotron-3.5-transcribe`)

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | a published mixed quantization, its own download: 8-bit experts, 8-bit Mamba and attention, 16-bit embeddings and encoders (affine-8 g64) | yes | — |
| 4 (int4) | a published mixed quantization, its own download: 4-bit routed experts, 8-bit shared experts, 8-bit Mamba and attention, 16-bit embeddings and encoders (affine-4 g64) | yes | — |

| Tier | Path | English WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | — | — | — | — | — | — | — | — |
| 16 (bf16) | Optimized Exact | — | — | — | — | — | — | — | — |
| 16 (bf16) | Optimized Fast | — | — | — | — | — | — | — | — |
| 8 (int8) | Standard | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Exact | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Fast | — | — | — | — | — | — | — | — |
| 4 (int4) | Standard | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Exact | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Fast | — | — | — | — | — | — | — | — |
<!-- MEASURED_END -->
