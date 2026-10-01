# Whisper (large-v3 and large-v3 turbo)

Runtime of Whisper large-v3 and large-v3 turbo, the Dictation models for about 100 languages. This folder holds the
encoder, the decoder, the tokenizer, the decoding loop and the optimized path; the catalog entries are in
`Resources/models.json`.

**Screening numbers.** Every speed, energy and memory figure in the text below is a screening number: a v2-mini A/B
(21 clips, 3.6 min of audio) on an M5 Max, macOS 26.6, dated 28 Sep to 1 Oct 2026, two symmetric cycles where the table
says so and one clean pair otherwise. Screening picks levers; it is not the release measurement. The release figures
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

A tier is offered unless it breaks against 16: a clip left empty or cut short, a request error, English or average WER
5 points worse, or one language 10 points worse (the presence rule). Lower tiers are made on the Mac from the FP16
weights with plain affine group-64 rounding, never from a quantized download. No calibrated, searched, refit or
bias-aware recipe is used (Toby, 30 Sep 2026: calibration is training on the 16-bit outputs).

- **16 (fp16):** the checkpoint as published.
- **8 (int8): the encoder stays FP16, the decoder is affine 8-bit g64** (`floatModules: ["model.encoder"]`, 41 % of
  large-v3's quantizable weights and 78 % of turbo's). That is a choice of modules, not calibration. Reason: the encoder is the cost
  (turbo spends about 49 ms per 30-second window there, at the FP16 ceiling) and int8 weights at the encoder's size run
  at the FP16 rate, so quantizing it saves bytes but not time. The mixed recipe is faster and uses less energy than the
  uniform 8-bit recipe and transcribes the same 21 clips identically (screening below). Memory is higher than the uniform
  recipe's, by about 390–400 MB. An imported uniform 8-bit checkpoint no longer counts as this tier; Get makes it from
  the FP16 download.
- **4 (int4): absent.** Plain affine 4-bit fails the gate on both models. The 28 Sep full-v2 gate run (segmentation
  since fixed): large-v3 Japanese +2.09, format +0.18, one lost clip; turbo English +0.49, Turkish +2.44, format +0.74,
  two lost clips.

`tiers_offered` in `Resources/models.json` is what the app offers.

## What Vella optimizes

Always on once the load-time self-test passed on the Mac (revision `whisper-3-f16-model`, or `whisper-3` under
Optimized · Exact; stock MLX is the fallback):

- **Checkpoint-dtype model** (component `encoder`): the FP16 model runs in FP16, where stock promotes to Float32. Inexact
  against stock, so it is off under Optimized · Exact.
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
| Mixed 8 tier: FP16 encoder, affine-8 decoder, made from the FP16 source | catalog `floatModules` | recipe `:float=model.encoder` | inexact against its own Standard, like every Whisper tier (encoder checkpoint dtype; decoder token-exact); Optimized equals Standard on 21 of 21 mini clips | large-v3 (30 Sep): speed +2.9 % (45.05 → 46.35×), energy −5.8 % (74.20 → 69.90 J/min), memory +392 MB (2650 → 3042), 21 of 21 identical to the uniform 8-bit recipe. Turbo (1 Oct): +5.8 %, −10.5 %, +399 MB, 21 of 21 identical | on |
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
- **Calibrated 4-bit** (clip search plus least-squares refit, g32 and g64): rejected by Toby on 30 Sep before any run. Plain affine g64 is the only quantization.

## Quality gate

The gate decides whether a lever or a tier loses anything measurable. Against the base (the stock path at the same
precision for a lever; the 16 tier for a tier): English WER within the model's tolerance (0.1 pt, up to 0.2 pt where the
model's own run-to-run noise is larger; Whisper's noise includes a second sampling seed), the multilingual mean within a
similar noise-based limit, no language more than 2 pt worse, no empty or cut-off segment. The limits for each model are
in `Resources/benchmarks.json` (`tolerance_pt`, `tolerance_ml_pt`).

On the user's Mac, a self-test runs before the optimized path is used, in a child process with a deadline, on five
public clips. Exact components must reproduce stock's tokens, or the whole model runs stock. Each inexact component
(the checkpoint-dtype encoder) must stay within its tolerance and at most one word edit in total, or only that component
is dropped. A runtime check falls back to stock on non-finite logits. A failed verdict is sticky for that model's files,
GPU family, macOS build, worker version and revision.

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Figures pending: the 2.0.0 measurement has not been written into `Resources/benchmarks.json` yet (`figures_pending` is true), so no figure is shown. A figure that is not measured is —.

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`.

#### Whisper large-v3 (`whisper-large-v3`)

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (fp16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the fp16 weights; `model.encoder` kept at fp16 (40.8 % of the quantizable weights) | yes | — |
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
| 8 (int8) | affine group 64 from the fp16 weights; `model.encoder` kept at fp16 (78.0 % of the quantizable weights) | yes | — |
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
