# Nemotron 3.5 Streaming

Runtime of Nemotron 3.5 Streaming 0.6B, the Streaming model: text appears while you speak. It does not transcribe files
and is not used for Dictation. This folder holds the encoder, the RNN-T decoder, the streaming session and the
optimized path (`VellaNemotron*`); the catalog entry is in `Resources/models.json`. The Streaming worker shares the
Dictation worker's executable.

**Screening numbers.** Every speed, energy and memory figure in the text below is a screening number: a v2-mini A/B
(21 streaming clips, 3.6 min of audio) on an M5 Max, macOS 26.6, dated 30 Sep to 1 Oct 2026, clean measure brackets
only (contaminated samples were rerun). Screening picks levers; it is not the release measurement. The release figures
are the generated block at the end.

## What it is

| | |
|---|---|
| Catalog id | `nemotron-3.5-streaming-0.6b` |
| Publisher, licence | NVIDIA (2026). Upstream OpenMDW-1.1; the MLX conversion's card lists the NVIDIA Open Model License (`Resources/models.json` carries both) |
| Source checkpoint | `mlx-community/nemotron-3.5-asr-streaming-0.6b` (BF16) |
| Languages | 28 in the catalog |
| Parameters | 0.6B: encoder 95.5 %, prediction network 2.3 %, joint 1.5 %, prompt 0.7 % |

Architecture: a cache-aware FastConformer encoder with an RNN-T decoder (a 2-layer LSTM predictor and a joint). The
session encodes 4-frame chunks and keeps bounded audio and mel state; it never recomputes the utterance. Pinned
revisions and download sizes are in `Resources/models.json`.

## Tiers offered, and why

A tier is offered unless it breaks against 16 (the presence rule, `lab/bench/gate_check.py`): a clip empty or cut short where
16 had the words, a request error or worker exit, English WER or the multilingual mean 5 points worse, or any supported
language 10 points worse. Lower tiers are made on the Mac from the BF16
weights with plain affine group-64 rounding, never from a quantized download. No calibrated, searched, refit or
bias-aware recipe is used (Toby, 30 Sep 2026: calibration is training on the 16-bit outputs). The predictor's LSTM stays
BF16 in every tier.

- **16 (bf16) and 8 (int8): offered.** The shipped verdict in `Resources/benchmarks.json` (the 29 Sep models-table round,
  `lab/notes/models-table-ROUND.md`; it predates the 2.0.0 measurement, which replaces it) puts the 8 tier at multilingual
  +0.55 against a limit of 0.10: worse than 16 by the recommendation gate, nothing broken, so it is offered.
- **4 (int4): absent.** The same verdict, for plain affine g64: English +9.59, multilingual +9.25, Turkish +15.28,
  15 clips empty or cut short where 16 had the words. A calibrated recipe (clip search plus least-squares refit, g32) brought the error back to the 8-bit level
  (English −0.05, multilingual +0.44 on v2-quick) but still lost one clip. Toby's ruling excludes it, so the tier stays
  absent.

`tiers_offered` in `Resources/models.json` is what the app offers.

## What Vella optimizes

Standard (stock MLX) computes like the reference: Float32 mel into BF16 weights, so every activation is Float32, as in
mlx-audio's `stream_generate` (default `dtype=mx.float32`) and NeMo's FP32 inference. MLX converts each BF16 weight to
Float32 on every call, which is why the 16 tier's Standard row is slower than the 8 tier's (a quantized matmul takes
Float32 input without converting its weights). Checked 3 Oct 2026, `lab/notes/STANDARD-FAITHFULNESS-2026-10-03.md`.

The encoder chunk is launch-bound: about 50 small kernels per layer for a 4-frame chunk. Each streaming optimization
below is on by default, bit-identical to stock except where marked, and active only after the load-time self-test passed
on the Mac (revision `nemotron-stream-5`; the self-test is described under Quality gate). `VELLA_NEMO_<NAME>=0` disables one; `VELLA_FORCE_STOCK=1` disables all.

- **Float32 weights, request coalescing, batched decode, position cache, K/V cache of the last frames, one mel call per
  request:** exact.
- **Fused conformer layer** (about 16 dispatches per layer instead of about 50): inexact (summation order), held to the
  self-test tolerance (see Quality gate) and judged by the WER gate. Off under Optimized · Exact.
- **BF16 Linears** on the small-M kernel, with the fused layer, on BF16 checkpoints: inexact, off under Optimized · Exact.

Their effect is the Optimized rows against the Standard rows in the generated block below.

Levers kept from the kernel rounds (opt-in; with none set every gate key is byte-identical; "default" is the state in the
code at this commit, and the release defaults are set after the measurement):

| Lever | Switch | Revision | Exact? | Screening result | Default |
|---|---|---|---|---|---|
| Keep MLX's buffer cache between streaming requests (requests last about 100 ms, so allocation is a large share) | `VELLA_NEMO_KEEPCACHE=1` | `keepcache-1` | exact | BF16 (30 Sep): speed +18.0 % (28.3 → 33.4×), energy −10.9 % (55.48 → 49.43 J/min), 21 of 21 identical. Long-stream check (1 Oct): +28 MB warm maximum over the baseline against a limit of 80 MB, committed text identical | off |
| Joint output projection batched: a chunk's remaining frames in one BF16 small-M pass | `VELLA_NEMO_JOINTBATCH=1` | `jointbatch-1` | inexact, borderline; off under Exact by code | BF16 (30 Sep, two pairs): speed +3.0 % and +3.3 %, energy −7.8 % and −3.3 %, 21 of 21 identical | off |

Both together against the previous default (30 Sep): 28.3 → 34.1× (+20.5 %), 55.48 → 48.1 J/min (−13 %), chunk latency
p50/p95 9.2/11.6 → 7.4/9.7 ms, peak memory +55 MB. Joint batching is admitted only on dense (BF16) checkpoints and
only with batched decoding.

Open follow-up: in the long-stream check both arms, with and without keep-cache, grew about 72 MB per hour. The lever
did not cause it, but the 20 minutes of audio ran in 40 s of wall time, so the slope is extrapolated and needs a
real-time stream to confirm.

## Rejected levers

Numbers are speed / energy against the arm without the lever, v2-mini, unless noted.

- **Native int8 encoder Linears** (`VELLA_NEMO_QLINEAR`, 8 tier; 1 Oct): −2.1 % / +6.9 %. At 4 rows the affine kernel ties or loses to MLX's quantized matmul (feed-forward block 25.5 against 27.6 µs at 8-bit, 25.8 against 25.4 µs at 4-bit).
- **Quantized joint on the affine kernel** (`VELLA_NEMO_QJOINT`, 8 tier; 1 Oct): +0.8 % / −0.8 %. It wins per block (21.0 against 24.8 µs) but the joint is a small share of a chunk.
- **Prompt without the one-hot** (folded into a per-language bias; 30 Sep): −0.6 % / −4.5 % for one pair but −2.5 % against the mean of three same-configuration samples (spread 3 %), so in noise. A cached one-hot has no effect (prompt step 1.77 against 1.75 ms per chunk).
- **Mel as one GPU kernel**: estimated at 1.6 % or less (mel is about 0.19 ms of a 9.6 ms chunk), not built.
- **Add and LayerNorm in the previous GEMV's epilogue**: estimated about 5 %, not built. It needs ordering across threadgroups, and Metal's device atomics are relaxed-only.
- **Native tile kernels for 9–256 rows** (`qtile-1`): not applicable, no GEMM in the streaming session reaches 9 rows.
- **Mixed tier (16-bit encoder, 8-bit decoder)**: not meaningful, the predictor is already BF16 in every tier and the joint is 1.5 % of the weights.
- **Compiled decode step**: not applicable, RNN-T greedy decoding takes about one predictor step per 320 ms chunk (under 0.5 % of a chunk).
- **Calibrated int4** (mse g32): rejected by Toby on 30 Sep; plain affine g64 is the only quantization.

## Quality gate

**Release gate** (offline, full v2, `lab/bench/gate_check.py`). The gate decides whether a lever or a tier loses anything
measurable. Against the base (the stock path at the same precision for a lever; the 16 tier for a tier), all of these must
hold: English WER and format CER each within the model's tolerance T (0.1 pt, up to 0.2 pt where the model's own run-to-run
noise plus 0.05 is larger); the multilingual mean within its own noise-based limit (0.1 to 0.3 pt); no supported language
with at least 5 minutes of suite audio more than 2 pt worse; no lost clips (the allowance is zero): on English and
supported-language clips with reference words, an empty hypothesis or a deleted tail counts as lost only when it removes at
least 3 reference words the base transcribed correctly (`TAIL_WORDS`); no request error or worker exit. The limits for each
model are in `Resources/benchmarks.json` (`tolerance_pt`, `tolerance_ml_pt`). Commit timing is not checked in these offline
runs. For a streaming model, a tier that fails only the multilingual criteria still passes when English is within T and its
speed is at least 1.25 times the fastest tier that passes outright (`STREAM_SPEED_TRADE`); its reason states the trade.

**Self-test on the user's Mac** (`Worker/Sources/VellaStreamingWorker/SelfTest.swift`), run before the optimized path is used,
in a child process with a deadline. It plays one stream of two public clips (clip-b, 1.2 s of silence, clip-e) through the
production streaming session in 100-ms packets, on stock MLX and then on the optimized path of the same loaded model. The
committed text must be non-empty and the encoder outputs finite. Without the fused layer every reply (committed and partial
text, frame counts, done) must be identical to stock's. With the fused layer the stream must stay within its tolerance
(`FusedTolerance`): encoder relative RMS ≤ 1e-2, at most one committed-word edit, every commit at most one packet from
stock's, at most two replies whose partial text differs, every other reply field identical. A failure of this one test
runs the whole model on stock; there is no per-component drop in the streaming self-test. A failed verdict is sticky for
that model's files, GPU family, macOS build, worker version and revision. If the optimized path fails at run time, the
stream is replayed on stock (up to about 10 minutes of audio).

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Figures pending: the 2.0.0 measurement has not been written into `Resources/benchmarks.json` yet (`figures_pending` is true), so no figure is shown. A figure that is not measured is —.

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor and every kept module stays at the source dtype. The predictor's LSTM stays at bf16 at every tier.

#### Nemotron 3.5 Streaming (`nemotron-3.5-streaming-0.6b`)

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the bf16 weights | yes | — |
| 4 (int4) | affine group 64 from the bf16 weights | no | — |

| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
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
