# Whisper (large-v3 and large-v3 turbo)

Runtime of Whisper large-v3 and large-v3 turbo, the Dictation models for about 100 languages. This folder holds the
encoder, the decoder, the tokenizer, the decoding loop and the optimized path; the catalog entries are in
`Resources/models.json`.

**Screening numbers.** Every speed, energy and memory figure in the text below is a screening number: a v2-mini A/B
(21 clips, 3.6 min of audio) on an M5 Max, macOS 26.6, dated 28 Sep to 1 Oct 2026, one clean pair per lever unless noted. The
1 Oct spread results (`lab/notes/KERNEL-MATRIX-2026-09-30.md`, Whisper results) used two symmetric cycles, four clean
samples per arm. Screening picks levers; it is not the release measurement. The release figures
are the generated block at the end.

## What it is

| | Whisper large-v3 | Whisper large-v3 turbo |
|---|---|---|
| Catalog id | `whisper-large-v3` | `whisper-large-v3-turbo` |
| Publisher, licence | OpenAI, Apache-2.0 (November 2023) | OpenAI, MIT (2024) |
| Source checkpoint | `mlx-community/whisper-large-v3-asr-fp16` | `mlx-community/whisper-large-v3-turbo-asr-fp16` |
| Languages | about 100 | the same |
| Parameters | 1.55B, 32 decoder layers | 0.8B, large-v3 pruned to 4 decoder layers and fine-tuned |

Architecture: an encoder-decoder transformer. The encoder always runs the padded 30-second window (1500 rows), whatever
the length of the segment; the decoder writes the transcript token by token, with temperature fallback sampling (seeded,
so a run is repeatable). Vella gives Whisper longer segments than other models (at least 20 s where the audio allows).
Pinned revisions and download sizes are in `Resources/models.json`.

## Tiers offered, and why

A tier is offered unless it breaks against 16 (the presence rule, `lab/bench/gate_check.py`): more clips empty or cut short
where 16 had the words than the base's seed allowance, a request error or worker exit, English WER or the multilingual mean
5 points worse, or any supported language 10 points worse. Whisper has a seed allowance because its temperature fallback
samples: a clip lost within it is sampling noise, not a rejected tier. Lower tiers are made on the Mac from the FP16
weights with plain affine group-64 rounding, never from a quantized download. No calibrated, searched, refit or
bias-aware recipe is used (Toby, 30 Sep 2026: calibration is training on the 16-bit outputs).

- **16 (fp16):** the checkpoint as published.
- **8 (int8): the encoder stays FP16, the decoder is affine 8-bit g64** (`floatModules: ["model.encoder"]`, 41 % of
  large-v3's weight bytes and 78 % of turbo's). That is a choice of modules, not calibration. Reason: the encoder is the cost
  (turbo spends about 49 ms per 30-second window there, at the FP16 ceiling) and int8 weights at the encoder's size run
  at the FP16 rate, so quantizing it saves bytes but not time. The mixed recipe is faster and uses less energy than the
  uniform 8-bit recipe and transcribes the same 21 clips identically (screening below). Memory is higher than the uniform
  recipe's, by about 390–400 MB. An imported uniform 8-bit checkpoint no longer counts as this tier; Get makes it from
  the FP16 download.
- **4 (int4): absent.** Plain affine 4-bit loses clips on both models, which is what makes a tier absent (the presence
  rule). The shipped verdict in `Resources/benchmarks.json` (the 29 Sep models-table round,
  `lab/notes/models-table-ROUND.md`; the 2.0.0 measurement replaces it): large-v3 one clip empty or cut short where 16 had
  the words, turbo two; both also fail the recommendation gate (large-v3 Japanese +2.09, format CER +0.18; turbo English
  +0.49, Turkish +2.44, format CER +0.74).

`tiers_offered` in `Resources/models.json` is what the app offers.

## What Vella optimizes

Standard (stock MLX) is activation-dtype-faithful to mlx-whisper on the shipped FP16 checkpoints
(`sinusoids(...).astype(dtype)`). The checkpoints omit the encoder's positional table and the loader synthesises it in
that dtype; until 3 Oct 2026 it was Float32, which promoted the whole encoder and decoder to Float32 with every FP16
weight re-cast per call, and running in FP16 was counted as an optimized `encoder` component
(`lab/notes/STANDARD-FAITHFULNESS-2026-10-03.md`). Vella keeps its pre-existing Double-trig sinusoid values:
about 1.85% of table entries differ from mlx-whisper's Float32-trig values by one FP16 ulp, so this is not bitwise
reference equivalence. Mel is always rounded to FP16; arbitrary FP32/BF16 sources are not proven reference-equivalent.

Always on once the load-time self-test passed on the Mac (revision `whisper-4`, the same under Optimized · Fast and
Optimized · Exact, because every component is exact; stock MLX is the fallback):

- **GPU-side decoder** (component `decoder`, exact): the greedy decode loop runs on the GPU, with a finite check on every logit tensor it uses.
- **Fused decode step** (listed as `fused_decode` in a quantized tier's recipe, exact, quantized checkpoints only): a
  quantized decode step is launch-bound at one token, so one GEMV serves q, k and v, one kernel appends the new K/V
  rows and lays q out per head, and one kernel does the residual add and the following LayerNorm, folding in the
  preceding Linear's bias. Token-exact against stock. At FP16 the step is GEMV-bandwidth-bound and the fusion was
  within noise, so dense checkpoints keep the plain step. Screening, 28 Sep, large-v3 int4: 36.5 → 38.1× and
  104.7 → 95.9 J/min.

Their effect is the Optimized rows against the Standard rows in the generated block below.

Levers kept from the kernel rounds:

| Lever | Switch | Revision | Exact? | Screening result | Default |
|---|---|---|---|---|---|
| Mixed 8 tier: FP16 encoder, affine-8 decoder, made from the FP16 source | catalog `floatModules` | recipe `:float=model.encoder` | exact against its own Standard (decoder token-exact) | large-v3 (30 Sep): speed +2.9 % (45.05 → 46.35×), energy −5.8 % (74.20 → 69.90 J/min), memory +392 MB (2650 → 3042), 21 of 21 identical to the uniform 8-bit recipe. Turbo (1 Oct): +5.8 %, −10.5 %, +399 MB, 21 of 21 identical | on |
| Keep MLX's buffer cache between dictation requests (shared dictation service) | `VELLA_DICTATION_KEEP_CACHE=0` restores the per-request clear | — | exact | large-v3 8 (1 Oct): +0.3 % / +1.7 %, −12 MB; turbo 8: +0.8 % / +0.7 %, −8 MB. No effect; kept as the shared default because it is harmless | on |

No Whisper-specific switch is set by the release's measurement plan: Whisper runs with no opt-in lever.

## Rejected levers

Numbers are speed / energy against the arm without the lever, v2-mini.

- **Native int8 weight operand** (probe, 30 Sep): the GEMM rate equals FP16 at 1500 rows (52–60 against 49–60 TOPS), so no throughput gain. W8A8 (int8 × int8) runs 1.50–1.66× the FP16 kernel, but it is inexact and needs a new weight format; not pursued.
- **Native int8/int4 tile kernel** (SmallMGEMM `qtile-1`, 9–256 rows): not applicable, the encoder GEMMs are 1500 rows and the decoder's other GEMMs are 3 rows (prefill) or 1500 (cross-attention). The tile runs flat at 31–36 TFLOPS for 512–749 rows, below MLX's 8-bit path (40–50) and FP16 (45–61).
- **Dense encoder over dequantized 8-bit weights** (`VELLA_WHISPER_ENC_DEQUANT`, 30 Sep): +2.6 % / −7.3 % but +1,064 MB peak. Superseded by the mixed tier and removed.
- **Preallocated self-attention K/V** (exact; 30 Sep): +1.3 % / −2.1 %, under 3 %.
- **Bias and GELU folded into kernels; compiled decode step**: rejected on the profile, not built. A custom-kernel call costs 3.4× a binary op on the host, the loop is host/GPU-balanced, and a compiled step only removes host work (Qwen, exact: 1 % or less on every precision). Turbo is encoder-bound.
- **Decode-step GEMV for fc2** (`VELLA_WHISPER_GEMV`, tolerant `int8_gemv`/`int4_gemv`; 1 Oct): large-v3 8 +0.1 % / +0.9 %, turbo 8 +0.4 % / +0.5 %, 21 of 21 identical. Only one of about nine GEMVs per layer qualifies (K ≥ 2048).
- **Truncated encoder context** (the encoder on the segment's frames plus a margin): failed the model's own self-test. Word edits over the five self-test clips (bound 1): turbo 2 at 2, 5, 10 and 15 s of margin; large-v3 3, 4 and 4 at 2, 5 and 10 s, while the exact components stayed token-exact. The model needs the full padded window.
- **Calibrated 4-bit** (clip search plus least-squares refit, g32 and g64): rejected by Toby on 30 Sep, after the day smokes (all four checkpoints loaded and ran) and before any A/B or quality run. Plain affine g64 is the only quantization.

## Quality gate

**Release gate** (offline, full v2, `lab/bench/gate_check.py`). The gate decides whether a lever or a tier loses anything
measurable. Against the base (the stock path at the same precision for a lever; the 16 tier for a tier), all of these must
hold: English WER and format CER each within the model's tolerance T (0.1 pt, up to 0.2 pt where the model's own run-to-run
noise plus 0.05 is larger; Whisper's noise pair is two sampling seeds); the multilingual mean within its own noise-based
limit (0.1 to 0.3 pt); no supported language with at least 5 minutes of suite audio more than 2 pt worse; no lost clips
beyond the base's seed allowance (the most clips one sampling seed loses against the other in the noise pair): on English and
supported-language clips with reference words, an empty hypothesis or a deleted tail counts as lost only when it removes at
least 3 reference words the base transcribed correctly (`TAIL_WORDS`); no request error or worker exit. The limits for each
model are in `Resources/benchmarks.json` (`tolerance_pt`, `tolerance_ml_pt`).

**Self-test on the user's Mac** (`FastPathSelfTest.swift`), run before the optimized path is used, in a child process with
a deadline, on the five default public clips. Whisper declares no tolerant component (`fastPathTolerantComponents` is
empty), so there is no tolerance stage: the test is token-exact. Per clip it transcribes with the stock path, then with the
optimized path, and the two token sequences must be identical, non-empty and finite, or the whole model runs stock. Both
paths run the same encoder in the checkpoint dtype, so the test compares the decoder components; Optimized · Fast and
Optimized · Exact run the same components. A runtime check falls back to stock on non-finite
logits. The runtime fallback now reruns the same FP16 encoder, like mlx-whisper; it does not rescue FP16 encoder overflow with a Float32 rerun. A failed verdict is sticky for that model's files, GPU family, macOS build, worker version and revision.

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Figures pending: the 2.0.0 measurement has not been written into `Resources/benchmarks.json` yet (`figures_pending` is true), so no figure is shown. A figure that is not measured is —.

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor and every kept module stays at the source dtype.

#### Whisper large-v3 (`whisper-large-v3`)

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (fp16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the fp16 weights; `model.encoder` kept at fp16 (40.8 % of the source checkpoint's weight bytes) | yes | — |
| 4 (int4) | affine group 64 from the fp16 weights | no | — |

| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (fp16) | Standard | — | — | — | — | — | — | — | — |
| 16 (fp16) | Optimized Exact | — | — | — | — | — | — | — | — |
| 16 (fp16) | Optimized Fast | — | — | — | — | — | — | — | — |
| 8 (int8) | Standard | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Exact | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Fast | — | — | — | — | — | — | — | — |
| 4 (int4) | Standard | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Exact | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Fast | — | — | — | — | — | — | — | — |

#### Whisper large-v3 turbo (`whisper-large-v3-turbo`)

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (fp16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the fp16 weights; `model.encoder` kept at fp16 (78.0 % of the source checkpoint's weight bytes) | yes | — |
| 4 (int4) | affine group 64 from the fp16 weights | no | — |

| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (fp16) | Standard | — | — | — | — | — | — | — | — |
| 16 (fp16) | Optimized Exact | — | — | — | — | — | — | — | — |
| 16 (fp16) | Optimized Fast | — | — | — | — | — | — | — | — |
| 8 (int8) | Standard | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Exact | — | — | — | — | — | — | — | — |
| 8 (int8) | Optimized Fast | — | — | — | — | — | — | — | — |
| 4 (int4) | Standard | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Exact | — | — | — | — | — | — | — | — |
| 4 (int4) | Optimized Fast | — | — | — | — | — | — | — | — |
<!-- MEASURED_END -->
