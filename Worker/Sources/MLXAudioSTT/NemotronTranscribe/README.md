# Nemotron 3.5 Transcribe

Runtime of Nemotron 3.5 Transcribe 30B-A4B, a Dictation model offered beside Parakeet v3 Ultra on Macs with the memory
for it. It is offline: the text of a segment arrives once the whole segment is encoded, so it is never the Streaming
model and never the first-run default. The catalog entry is in `Resources/models.json` and the descriptor in
`Sources/VellaCore/Models/NemotronTranscribe/`.

**Screening numbers.** Every speed and memory figure in the text below is a screening number: a short opt-in run on an
M5 Max with 128 GB, macOS 27.0.1, on 28 Oct 2026, on two public FLEURS Polish clips. It is not the release measurement,
which is the generated block at the end (empty until the v2 benchmark is run).

## What it is

| | |
|---|---|
| Catalog id | `nemotron-3.5-transcribe` |
| Publisher, licence | NVIDIA (2026), OpenMDW-1.1. The BF16 download carries `LICENSE`, `THIRD_PARTY_NOTICES.md` and `licenses/`; the derived precisions load from that folder |
| Source checkpoint | `nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B` (BF16, SHA-256 `03142dde…acff2`) |
| Parameters | 30B in total, about 4B active per token. A 52-layer Nemotron-H decoder (Mamba-2, attention and 128-expert MoE layers, 6 experts per token) is fed by a feature-stacking RoPE Transformer speech encoder (32 layers) and a Sortformer speaker encoder (31 layers) |

The port follows mlx-audio at commit `92decb7` (`mlx_audio/stt/models/nemotron_transcribe`, MIT), which follows NVIDIA
NeMo Speech (Apache-2.0):

- `NemotronTranscribeDecoder.swift`: the decoder, with the vendored mlx-lm SSM kernels, and the MTP head. The SSM scan,
  its skip connection and the gated norm run in FP32, as NeMo keeps A_log, D, dt_bias and the state in FP32. The MoE
  router is FP32 too.
- `NemotronTranscribePerception.swift`: log-mels from the checkpoint's own filter bank and window, both encoders, the
  speaker model's FIFO and AOSC speaker cache over 40 s windows, and the sinusoidal speaker fusion.
- `NemotronTranscribeRecipe.swift`: the int8/int4 recipe made at load.
- `NemotronTranscribeModel.swift`: loading for all three tiers, the prompt, decoding, chunking and the vocabulary guard.
- `NemotronTranscribeText.swift`: the parts that need no MLX, covered by `Worker/Tests/VellaWorkerTests/NemotronTranscribeTests.swift`.

**Prompt.** Dictation always uses the checkpoint's plain ASR prompt, in the `nemotron3p5` chat format with thinking off.
The speaker-attributed, rich-transcription and translation prompts are never used. Any markup that still appears is
removed and the words between tags are kept: `<spk:N>`, `<ev:…>`, `<sty:…>` and `<think>` blocks.

**Vocabulary.** The user's `vocabulary.json` (`docs/vocabulary.md`) adds `Contextual vocabulary: a, b, c` to the prompt.
Only the plain `words` go in, never Parakeet's acoustic entries or variants. The hint can make words up: on the
maintainer's speech, a 17-word list made the model append "Poznań", which was never spoken. When the last sentence (or
the whole segment) is only list words, the same audio embeddings are decoded once more without the list. The
candidate is dropped only when that transcript has no words after the last word the two share. The list can also bend
spellings ("usunąć" became "usunąń" once), and nothing here undoes that.

**Segments.** The app cuts dictation and files into segments at pauses: at most 30 s, preferring a cut after 20 s for
this model, like Whisper. A worker request is at most about 65 s of audio. NVIDIA's offline model is meant for chunks
of two minutes or less: on a 5-minute recording, small numeric changes flipped punctuation and one run dropped its last
two sentences. The app's segments always satisfy that. `NemotronTranscribeChunking` still cuts anything longer at the
quietest 100 ms in the last 20 s before 120 s, as a backstop.

## Tiers offered, and why

NVIDIA's BF16 checkpoint is the only download. int8 and int4 are made from it at load, like every other family's
8 and 4: Vella writes a directory holding only `vella-derived.json`, and the worker quantizes tensor by tensor from
the source file. Each source tensor is read, quantized, evaluated and dropped before the next, so the peak is the
derived model plus about two source tensors (the stacked experts are a transposed view, so quantizing one makes a
contiguous copy: about 2.6 GB for the largest). Nothing extra is stored.

- **16** is NVIDIA's BF16 original in NeMo layout, one `model.safetensors`. Keys are mapped at load
  (`NemotronTranscribeKeys`). The CTC-timestamp head is not loaded; the MTP head is loaded as shipped.
- **8**: every decoder projection (routed and shared experts, Mamba in/out, attention) is int8 affine, group 64.
- **4**: routed experts (87 % of the parameters) are int4, group 64. Everything a token always passes through is int8.

The recipe is `NemotronTranscribeRecipe`, applied by this architecture's loader, like Qwen's float audio tower. In 8
and 4, embeddings, the output head, norms, the router (FP32), Mamba A_log/D/dt_bias (FP32), `conv1d` and both
encoders stay as shipped. The MTP draft head is quantized at load as well: routed experts 4-bit, the rest 8-bit, in
both tiers. It changes how many drafts are accepted, never the output.

The mixes were chosen by teacher-forced checks against a layer-streamed BF16 reference (4 clips, 512 tokens), not by any
calibration of the weights: the codes are NVIDIA's weights rounded by MLX's affine quantize. Results: int8 KL 0.0107,
top-1 98.2 %; int4 KL 0.0144, top-1 97.9 %; naive all-4-bit KL 0.061, top-1 96.9 %.

**Derivation checks** (28 Oct, M5 Max 128 GB).
- Golden test (`derivationMatchesTheReferenceExports`, opt-in): derived from the real BF16, one tensor at a time,
  against the reference Python exports (mlx-audio, MLX 0.32.4). Weights, scales and biases are bit-identical, and the
  kept tensors byte-identical: 1,611 of 1,611 for each of int4 and int8, including the 34 MTP tensors. MLX peak was
  4.0 GB, in 14.5 s with a warm disk cache.
- A real int4 load through the worker took 39.6 s (read, quantize, warm-up). Footprint was 22.1 GB, and MLX active
  memory 21.8 GB, the same as the export. The transcript was identical to the export's.
- The fixture test (`derivesInt4AndInt8FromTheNeMoLayout`, MLX CPU lane) builds a tiny NeMo-layout model and checks:
  every module's bits and group size; shapes; equality with MLX's own quantize; kept tensors byte for byte; and the
  dequantization error within MLX's affine bound. That bound is half a step, plus up to one step where MLX's
  edge-snapping clips a group, plus BF16 scale rounding. Measured worst: 1.0 step at int4, 1.49 at int8.

Each tier is offered where this Mac's memory fits it (`Sources/VellaCore/Catalog/MemoryFit.swift`).

## What Vella optimizes

- **Draft-and-verify decoding (MTP self-speculation).** The checkpoint's MTP head drafts 4 chained tokens, and the main
  model verifies them in one pass with one host sync per pass. On a rejection, Mamba states are restored and attention
  caches trimmed. It is inexact: batched verification changes near-tie choices. So Optimized · Exact and stock MLX
  (`VELLA_FORCE_STOCK=1`) decode plain greedy, and `VELLA_NEMOTRON_TRANSCRIBE_MTP=0` turns it off for lab A/B. The
  worker's status reports it as the `mtp` optimization. Screening: about 1.9× faster decoding (15 s clip 0.96 → 0.46 s,
  60 s clip 3.5–4.4 → 1.9–2.8 s).
- **Runtime fallback.** A verify pass that throws an MLX error or yields non-finite logits decodes that chunk again
  plain greedy, and draft-and-verify stays off until the model is reloaded; the worker pushes a `fallback` status and
  names it in the engine reason (the other models fall back to stock the same way). Checked live on int4 (6 Nov):
  with `VELLA_TEST_OPTIMIZED_FAULT=throw` or `nonfinite`, v2-mini ran with 0 errors and 21 of 21 transcripts equal to
  Standard.
- **Runaway guard.** A draft-and-verify run that reaches the token limit without an end token is a repetition loop;
  that chunk is decoded again plain greedy, and draft-and-verify stays on. Full v2 at int4 (6 Nov): one 20 s segment
  of a DiPCo dinner-party recording repeated "It's awesome." 248 times under draft-and-verify (English WER +1.67 pt
  for the whole tier from that one clip); with the guard the clip has 833 words and no loop (Standard: 854). The status
  reports `runaway_retries`.
- **MLX buffer cache kept between chunks** on the optimized paths, as the dictation service keeps it between requests
  (`VELLA_DICTATION_KEEP_CACHE=0` restores the per-chunk clear; Standard keeps it). Exact.
- **Warm-up at load.** Loading decodes 2 s of faint noise. Without it, the first request paid about 11 s of one-time
  kernel preparation (a 25 s segment took 12.2 s, then 0.75 s once warm). With it, load took 8.8 s and the first
  segment 0.78 s.
- **No self-test child** (`NemotronTranscribeRuntime.hasFastPath` is false; gate revision `nemotron-transcribe-1`). Qualifying would load a second copy of
  21–68 GB in a child process. The MTP chain is checked by the main model token by token, and its tolerance is
  measured by the parity test below.

## Rejected levers

Night of 6 Nov (M5 Max 128 GB, macOS 27.0.1, int4, v2-quick ABBA, Mac otherwise idle; the patch is kept in the lab):
- Prebuilt lhs indices for the expert gather matmuls (MLX builds an `arange` per call when none are passed) plus
  `compile(shapeless:)` fusion of the weight-free elementwise chains (ReLU², router sigmoid, Mamba dt and SiLU, gated
  norm prologue), together with the cache reuse above: 23.45 → 23.7× (+1.1 %), transcripts identical (122 of 122).
  Below the 3 % keep rule; removed. The decode is not bound by these small dispatches.
- Draft depth 3 / 4 / 5: 29.3–29.6× / 29.5–29.6× / 29.0–29.3×, flat; 4 kept.
- Where the time goes (per-chunk profile, int4 Fast, v2-quick): audio encoders 5 % of the wall time; the rest is the
  30B-A4B decoder's prefill (~250 prompt and audio tokens) and decode, ~9.6 ms per output token.

The research runner's compiled single-token Mamba and MoE blocks (its `mx.compile` patch) are not ported yet; the
fusion result above makes a large gain from it unlikely, so it needs a profile of the step first. Skipping the speaker encoder does not apply: its fused features enter the
speech embeddings for every recording, one speaker included.

## Quality gate

**Parity** (opt-in test `parityWithPythonReference`, int4). It compares token IDs with mlx-audio `92decb7` (MLX 0.32.4):
`generate_step` with 512-token prefill blocks, and the research runner's `generate_chain` at depth 4. Two FLEURS
Polish clips, 15 s and 60 s (the 60 s clip crosses the 40 s speaker window), each with no list and with a three-word
list. Stock decoding is token-identical on 3 of 4 runs. The fourth (60 s with a list) differs in 4 near-tie words, and
mlx-audio's own chain differs from its own stock there too. MTP is token-identical to the reference chain on the 15 s
clip and has the same words as Swift stock on the 60 s clip without a list. The test fails on any of those regressions
and also runs `generate()` end to end. Peak MLX memory was 23.1 GB.

**Release gate** (offline, full v2, `local gate_check.py`; run 6 Nov on M5 Max, macOS 27.0.1, build `nt-cc294836a0be`). Against the base (the 16 tier
for a tier, the plain-greedy path for draft-and-verify), the usual limits hold: English WER and format CER within the
model's tolerance; no lost clips (an empty hypothesis or a deleted tail counts as lost only when it removes at least 3
reference words the base transcribed correctly (`TAIL_WORDS`)); no request error or worker exit.

Verdicts (6 Nov) against bf16 Standard, with the noise floor from bf16 Standard vs bf16 Fast (English 0.00 pt,
multilingual 0.06 pt), so the limits are 0.10 pt English and 0.11 pt multilingual:
- bf16 Fast passes (English +0.00, multilingual +0.06, no lost clips).
- int4 Fast passes (English +0.09, multilingual −0.20); int4 Standard and Exact fail (English +0.21). The tier is
  offered on its default Fast path; its plain-greedy cells carry their own failure in the tooltip.
- int8 fails on both paths: multilingual mean +0.31 (Fast), +0.40 with Turkish +2.33 and format +0.11 (Standard).
- Exact decodes plain greedy like Standard: int4 full v2 gave 797 of 797 identical transcripts, so the int8 and bf16
  Exact cells reuse their Standard accuracy (speed is measured per cell).

Energy: the macOS 27 meter reads only the GPU without root (CPU, ANE and DRAM read 0), so the table's whole-chip
J / min stays empty. GPU-only, same night and meter, v2-quick: bf16 Standard 67.6, bf16 Fast 70.9, int8 Standard 96.8,
int8 Fast 94.5, int4 Standard 86.7, int4 Exact 89.1 J per audio minute; Parakeet v3 Ultra bf16 Fast 3.0. Dense bf16
costs less GPU energy per minute than int4 here. Three cells (bf16 Exact, int8 Exact, int4 Fast) had fewer than two
clean brackets.

**Known limits.**
- Faint background voices are skipped, which suits dictation. On a 36 s call recording, a distant second voice 25–27 dB
  below the speaker was left out, and so was a very quiet tail of the speaker's own words.
- The CTC word-timestamp head is not used, so there are no word timings.

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Measured 2026-11-06 on Apple M5 Max, macOS 27.0.1. English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately. Accuracy: v2 (239.7 min); speed, energy and peak RAM: v2-quick (22.5 min).

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides, unless its row states its own recipe; every other tensor and every kept module stays at the source dtype.

#### Nemotron 3.5 Transcribe (`nemotron-3.5-transcribe`)

Gate limits: English ≤ 0.10 pt, multilingual mean ≤ 0.11 pt.

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | made at load from the bf16 weights: 8-bit decoder projections, 16-bit embeddings, 16-bit head and encoders (affine-8 g64) | yes | fail; present; gate: multilingual mean +0.31 pt vs 16 (limit 0.11) |
| 4 (int4) | made at load from the bf16 weights: 4-bit routed experts, 8-bit other decoder projections, 16-bit embeddings, 16-bit head and encoders (affine-4 g64) | yes | pass; present |

| Tier | Path | English WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | 14.54 | 7.78 | 14.14 | 14.1× | — | 65250 | — | — |
| 16 (bf16) | Optimized Exact | 14.54 | 7.78 | 14.14 | 14.0× | — | 65248 | −1 % | — |
| 16 (bf16) | Optimized Fast | 14.54 | 7.80 | 14.20 | 18.0× | — | 65245 | +28 % | — |
| 8 (int8) | Standard | 14.57 | 7.89 | 14.54 | 19.4× | — | 37463 | — | — |
| 8 (int8) | Optimized Exact | 14.57 | 7.89 | 14.54 | 19.5× | — | 37523 | +1 % | — |
| 8 (int8) | Optimized Fast | 14.56 | 7.83 | 14.45 | 24.1× | — | 37543 | +24 % | — |
| 4 (int4) | Standard | 14.75 | 7.85 | 13.89 | 23.6× | — | 23881 | — | — |
| 4 (int4) | Optimized Exact | 14.75 | 7.85 | 13.89 | 23.2× | — | 23810 | −2 % | — |
| 4 (int4) | Optimized Fast | 14.63 | 7.81 | 13.94 | 29.3× | — | 23844 | +24 % | — |
<!-- MEASURED_END -->
