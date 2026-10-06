# Qwen3-ASR (1.7B and 0.6B)

Runtime of Qwen3 ASR 1.7B and 0.6B, Dictation models for languages Parakeet lacks, such as Chinese, Japanese and
Korean. This folder holds the audio tower, the text decoder and the optimized path; the catalog entries are in
`Resources/models.json`.

**Screening numbers.** Every speed, energy and memory figure in the text below is a screening number: a v2-mini A/B
(21 clips, 3.6 min of audio) on an M5 Max, macOS 26.6, one clean measure pair per lever, dated 28 Sep to 1 Oct 2026.
Screening picks levers; it is not the release measurement. The release figures are the generated block at the end.

## What it is

| | Qwen3 ASR 1.7B | Qwen3 ASR 0.6B |
|---|---|---|
| Catalog id | `qwen3-asr-1.7b` | `qwen3-asr-0.6b` |
| Publisher, licence | Qwen (Alibaba), Apache-2.0 (January 2026) | the same |
| Source checkpoint | `mlx-community/Qwen3-ASR-1.7B-bf16` | `mlx-community/Qwen3-ASR-0.6B-bf16` |
| Languages | 30 (the model card also lists 22 Chinese dialects) | the same 30 |
| Parameters | 1.7B | 0.6B |

Architecture: an audio tower (encoder) feeding a Qwen3 text decoder that writes the transcript token by token, built on
Qwen3-Omni. Pinned revisions and download sizes are in `Resources/models.json`.

## Tiers offered, and why

A tier is offered unless it breaks against 16 (the presence rule, `local gate_check.py`): a clip empty or cut short where
16 had the words, a request error or worker exit, English WER or the multilingual mean 5 points worse, or any supported
language 10 points worse. Lower tiers are made on the Mac from the BF16
weights with plain affine group-64 rounding, never from a quantized download. No calibrated, searched, refit or
bias-aware recipe is used (Toby, 30 Sep 2026: calibration is training on the 16-bit outputs). The audio tower stays
float at every tier, so 8 and 4 already are "16-bit tower, quantized decoder".

The final 1–2 Oct verdicts in `Resources/benchmarks.json` use plain affine g64 against the 16 tier.

- **1.7B: 16 only.** Int8 loses one clip where 16 had the words and Turkish WER is +42.64 pt
  (presence limit +10 pt). Int4 also loses one clip.
- **0.6B: 16 and 8.** Int4 is absent because it loses two clips where 16 had the words.

`tiers_offered` in `Resources/models.json` is what the app offers.

## What Vella optimizes

Always on once the load-time self-test passed on the Mac (revision `qwen3-asr-3-f32-encoder-p3`; stock MLX is the
fallback). Both components are exact:

- **`decoder`:** greedy decode pipelined with `asyncEval` (step N+1 is built from the still-lazy token N while the CPU
  consumes token N), and a prefill without the vocabulary projection whose output is discarded.
- **`encoder`:** the audio tower held in Float32 with host-side convolution lengths. The Float32 log-mel already
  promotes the stock tower to Float32 and MLX re-casts every BF16 weight inside every call; holding the weights in
  Float32 is the identical graph without those casts (bit-identical, two more bytes per parameter).

Their effect is the Optimized rows against the Standard rows in the generated block below. No further lever ships for
Qwen in this build.

Kept on the screening A/B but not integrated (1 Oct): the quantized prefill GEMMs on SmallMGEMM `qtile-1`
(`VELLA_QWEN_QTILE`) and the int8 audio tower (`quantizeModules: ["audio_tower.layers"]`, `VELLA_QWEN_QTOWER`). They
help only tiers that are absent today (1.7B 8: prefill +3.3 % speed / +0.5 % energy, int8 tower +1.2 % / −3.7 % and
−854 MB; 1.7B 4: prefill +4.4 % / −1.3 %; 0.6B 4: prefill +1.4 % / −5.1 %). The final-build review dropped them because
they ran under Standard and Exact and bypassed the self-test's stock baseline and the stock fallback. They need
model-owned activation, separate switches per tolerant component and fallback coverage before they can ship. The patch
is not published; it stays in the maintainers' lab.

## Rejected levers

Numbers are speed / energy against the arm without the lever, v2-mini. Where a lever has no effect on a tier it is
listed once.

- **Compiled decode step** (exact): 0.6B 4 +0.4 % / −1.5 %, 1.7B 8 token-exact (30 Sep); BF16 1.7B −0.4 % / +0.1 %, 0.6B +0.2 % / −1.7 % (28 Sep). The pipelined decode already hides the host work.
- **Calibrated int4** (lsq g64, 0.6B): +0.5 % / −1.1 %, English +1.77, gate fail (30 Sep). Also rejected by Toby's ruling.
- **Audio tower through the BF16 tile kernel** (two tests): the first test (30 Sep, 0.6B 4: −0.4 % / −0.2 %) was a null A/B, void, because the tower runs Float32 and the kernel never engaged. The corrected test on the BF16 tier (1 Oct): 0.6B +0.8 % / +0.2 %, multilingual +0.56, gate fail; 1.7B +0.7 % / −1.9 %, −580 MB, under 3 %.
- **The model's own cache clearing removed** (`VELLA_QWEN_KEEPCACHE`, exact; 30 Sep): 0.6B 4 +1.2 % / −0.7 %, 1.7B BF16 +1.1 % / −1.9 %. One request per segment makes decode bandwidth-bound, so allocation cost is small.
- **Shared keep-cache** (1 Oct): 0.6B 4 −0.5 % / 0.0 %, 1.7B 4 0.0 % / +4.2 %. It stays the shared dictation default (exact, harmless).
- **Decode-step Linears on the small-M GEMV** (`VELLA_QWEN_GEMV`, 1 Oct): 0.6B 4 −7.8 % / +6.5 %, 1.7B 4 −1.0 % / +18.5 %.
- **int8 tower** on 0.6B 8: +1.9 % / +0.2 %, −453 MB, under 3 % (memory noted). **Quantized prefill** on 0.6B 8: +1.3 % / −0.4 %, multilingual +0.10, gate fail.
- **int4 tower**: 0.6B 4 +2.3 % / −0.7 %, gate fail (2 of 21 clips identical); 1.7B 4 +1.2 % / +0.2 %, English +0.88, gate fail.
- **16-bit audio tower plus 8-bit decoder**: not applicable, every tier already is that.

The int8 tower's 0.45–0.85 GB memory saving is real and is the reason to revisit it with proper gating.

## Quality gate

**Release gate** (offline, full v2, `local gate_check.py`). The gate decides whether a lever or a tier loses anything
measurable. Against the base (the stock path at the same precision for a lever; the 16 tier for a tier), all of these must
hold: English WER and format CER each within the model's tolerance T (0.1 pt, up to 0.2 pt where the model's own run-to-run
noise plus 0.05 is larger); the multilingual mean within its own noise-based limit (0.1 to 0.3 pt); no supported language
with at least 5 minutes of suite audio more than 2 pt worse; no lost clips (the allowance is zero): on English and
supported-language clips with reference words, an empty hypothesis or a deleted tail counts as lost only when it removes at
least 3 reference words the base transcribed correctly (`TAIL_WORDS`); no request error or worker exit. The limits for each
model are in `Resources/benchmarks.json` (`tolerance_pt`, `tolerance_ml_pt`).

**Self-test on the user's Mac** (`FastPathSelfTest.swift`), run before the optimized path is used, in a child process with
a deadline, on the five default public clips. Both Qwen components are exact and must reproduce stock's tokens, or the
whole model runs stock. A runtime check falls back to stock if a decoder step or the encoder produces a non-finite value. A
failed verdict is sticky for that model's files, GPU family, macOS build, worker version and revision.

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Measured 2026-10-01 on Apple M5 Max, macOS 26.6. English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately. Accuracy: v2 (239.7 min); speed, energy and peak RAM: v2-quick (22.5 min).

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor and every kept module stays at the source dtype. The audio tower stays float at every tier.

#### Qwen3 ASR 1.7B (`qwen3-asr-1.7b`)

Gate limits: English ≤ 0.10 pt (noise measured 2026-09-28: 0.00 pt; not remeasured on this build), multilingual mean ≤ 0.10 pt (noise measured 2026-09-28: 0.00 pt; not remeasured on this build).

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the bf16 weights | yes | fail; fails presence (offered, never recommended): 1 clip empty or cut short where 16 had the words; Turkish +42.64 pt vs 16 (presence limit +10.0) |
| 4 (int4) | affine group 64 from the bf16 weights | yes | fail; fails presence (offered, never recommended): 1 clip empty or cut short where 16 had the words |

| Tier | Path | English WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | 15.00 | 6.67 | 14.04 | 26.6× | 81.03 | 4624 | — | — |
| 16 (bf16) | Optimized Exact | 15.00 | 6.67 | 14.04 | 29.6× | 72.73 | 5118 | +11 % | −10 % |
| 16 (bf16) | Optimized Fast | 15.00 | 6.67 | 14.04 | 29.6× | 72.73 | 5118 | +11 % | −10 % |
| 8 (int8) | Standard — Fails presence, never recommended | 15.11 | 6.59 | 19.01 | 36.7× | 71.35 | 3197 | — | — |
| 8 (int8) | Optimized Exact — Fails presence, never recommended | 15.11 | 6.59 | 19.01 | 44.3× | 64.81 | 3721 | +21 % | −9 % |
| 8 (int8) | Optimized Fast — Fails presence, never recommended | 15.11 | 6.59 | 19.01 | 44.3× | 64.81 | 3721 | +21 % | −9 % |
| 4 (int4) | Standard — Fails presence, never recommended | 18.32 | 7.03 | 15.96 | 47.3× | 56.23 | 2367 | — | — |
| 4 (int4) | Optimized Exact — Fails presence, never recommended | 18.32 | 7.03 | 15.96 | 61.5× | 51.43 | 2890 | +30 % | −9 % |
| 4 (int4) | Optimized Fast — Fails presence, never recommended | 18.32 | 7.03 | 15.96 | 61.5× | 51.43 | 2890 | +30 % | −9 % |

#### Qwen3 ASR 0.6B (`qwen3-asr-0.6b`)

Gate limits: English ≤ 0.10 pt (noise measured 2026-09-28: 0.00 pt; not remeasured on this build), multilingual mean ≤ 0.10 pt (noise measured 2026-09-28: 0.00 pt; not remeasured on this build).

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the bf16 weights | yes | fail; present; gate: English WER +0.15 pt vs 16 (limit 0.10); multilingual mean +0.32 pt vs 16 (limit 0.10) |
| 4 (int4) | affine group 64 from the bf16 weights | yes | fail; fails presence (offered, never recommended): 2 clips empty or cut short where 16 had the words |

| Tier | Path | English WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | 15.89 | 7.16 | 20.14 | 51.7× | 36.82 | 2142 | — | — |
| 16 (bf16) | Optimized Exact | 15.89 | 7.16 | 20.14 | 64.4× | 34.07 | 2406 | +25 % | −7 % |
| 16 (bf16) | Optimized Fast | 15.89 | 7.16 | 20.14 | 64.4× | 34.07 | 2406 | +25 % | −7 % |
| 8 (int8) | Standard | 16.04 | 7.17 | 20.46 | 60.7× | 33.58 | 1639 | — | — |
| 8 (int8) | Optimized Exact | 16.04 | 7.17 | 20.46 | 82.0× | 30.05 | 1920 | +35 % | −10 % |
| 8 (int8) | Optimized Fast | 16.04 | 7.17 | 20.46 | 82.0× | 30.05 | 1920 | +35 % | −10 % |
| 4 (int4) | Standard — Fails presence, never recommended | 17.56 | 8.25 | 24.93 | 68.4× | 28.71 | 1332 | — | — |
| 4 (int4) | Optimized Exact — Fails presence, never recommended | 17.56 | 8.25 | 24.93 | 96.4× | 25.60 | 1648 | +41 % | −11 % |
| 4 (int4) | Optimized Fast — Fails presence, never recommended | 17.56 | 8.25 | 24.93 | 96.4× | 25.60 | 1648 | +41 % | −11 % |
<!-- MEASURED_END -->
