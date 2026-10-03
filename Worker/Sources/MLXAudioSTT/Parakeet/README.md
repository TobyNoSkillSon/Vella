# Parakeet (v3 and v3 Ultra)

Runtime of Parakeet v3 and Parakeet v3 Ultra: the Dictation models Vella starts with. This folder holds the loader, the
TDT decoder and the optimized path (`FastParakeet*`); the catalog entries are in `Resources/models.json`, the shared
kernels in `Worker/Sources/SmallMGEMM`.

**Screening numbers.** Every speed, energy and memory figure in the text below is a screening number: a v2-mini A/B
(21 clips, 3.6 min of audio) on an M5 Max, macOS 26.6, one clean measure pair per lever unless noted, on the date given.
Screening picks levers; it is not the release measurement. The release figures are the generated block at the end.

## What it is

| | Parakeet v3 | Parakeet v3 Ultra |
|---|---|---|
| Catalog id | `parakeet-v3` | `parakeet-v3-ultra` |
| Publisher, licence | NVIDIA, CC BY 4.0 (August 2025) | Moondream, CC BY 4.0 (September 2026) |
| Source checkpoint | `animaslabs/parakeet-tdt-0.6b-v3-mlx`, published as FP32 | `selcukkubur/parakeet-ultra-mlx`, tensor-identical to `moondream/parakeet-ultra` |
| What Vella does with it | downloads the FP32 once, converts to BF16, keeps only BF16 | downloads BF16 |
| Languages | 25 European | the same 25 European |
| Parameters | 0.6B (627M: encoder 608.9M, prediction network 11.8M, joint 6.3M) | the same architecture |

Architecture: FastConformer encoder, TDT (token-and-duration transducer) decoder, Dictation only. Ultra is v3
post-trained for dictation; it is the model offered for a first dictation. Pinned revisions and download sizes are in
`Resources/models.json`.

## Tiers offered, and why

A tier is offered unless it breaks against 16 (the presence rule, `local gate_check.py`): a clip empty or cut short where
16 had the words, a request error or worker exit, English WER or the multilingual mean 5 points worse, or any supported
language 10 points worse. Lower tiers are made on the Mac from the 16-bit
weights with plain affine group-64 rounding (MLX `quantized`), never from a quantized download. No calibrated, searched,
refit or bias-aware recipe is used (Toby, 30 Sep 2026: calibration is training on the 16-bit outputs). The only choice
left is which modules are quantized.

For the 8 and 4 tiers the catalog keeps the prediction network and the joint at BF16 (`floatModules: ["decoder", "joint"]`,
1.84 % of the source checkpoint's weight bytes, +11 MB) and rounds the rest. That is a choice of modules, not calibration. Reason: the clip a
uniform 8-bit v3 loses is lost in the quantized prediction/joint network, not in the encoder (an int8 encoder alone
does not bring it back; a BF16 decoder and joint do), and a uniform 4-bit v3 cannot qualify its fast path at all (the
load-time exact stage differs from stock at clip-a, token 18, so the whole model runs stock).

Full-v2 presence screen, 1 Oct 2026, each recipe against the same build's 16 tier, plain affine g64, the quantized
rows of the 8 and 4 tiers that qualify on the native int8 and int4 encoder kernels (the table's "v3 4 uniform" row runs stock, see above):

| Recipe | Gate | English | Multilingual | Worst language | Lost clips | Presence |
|---|---|---|---|---|---|---|
| v3 8 uniform | fail | −0.21 | +0.31 | fr +1.43 | 1 | absent |
| v3 8, decoder and joint BF16 | pass | −0.12 | +0.15 | es +0.69 | 0 | present |
| v3 4 uniform | fail | +1.38 | +1.78 | fr +3.66 | 7 | absent |
| v3 4, decoder and joint BF16 | fail | +0.53 | −0.02 | sv +3.01 | 3 | absent |
| Ultra 8 uniform | fail | −0.00 | +0.31 | sv +1.08 | 0 | present |
| Ultra 8, decoder and joint BF16 | fail | −0.05 | +0.23 | sv +0.86 | 0 | present |
| Ultra 4 uniform | fail | +0.25 | +1.30 | sv +3.44 | 0 | present |
| Ultra 4, decoder and joint BF16 | fail | +0.07 | +0.79 | sv +2.37 | 0 | present |

Ultra's 8 and 4 tiers are worse than 16 by the gate but break nothing, so they are offered with the loss in their
figures. v3's 4 tier stays absent (3 lost clips). `tiers_offered` in `Resources/models.json` is what the app offers; v3's
8 tier is offered: the final release measurement confirms its presence. The screen above remains dated historical evidence.

## What Vella optimizes

Always on once the load-time self-test passed on the Mac (revision `parakeet-r2-dense-encoder`, plus
`+nax2+smallm-tile-1` while the NAX kernel is on, which is the default; stock MLX is the fallback):

- **Fused Conformer encoder** (`FastParakeetEncoder`, component `encoder`): exact.
- **TDT decoder as one compiled graph** (`FastParakeetTDT`, component `decoder`): 32 steps × 5 kernels, every weight a
  graph argument; exact.
- **Small-M BF16 GEMM** (`FastParakeetNAX`, `SmallMGEMM` tile kernel, component `nax_gemm`): at app segment lengths
  (about 16–150 rows) the encoder is weight-streaming GEMMs, and MLX's own NAX GEMM launches too few threadgroups for a
  40-core GPU. The split-K tile kernel reorders sums (≤ 1 BF16 ulp per GEMM), so it is inexact and is left off by
  Optimized · Exact. `VELLA_PARAKEET_NAX=0` turns it off.

Their effect is the Optimized rows against the Standard rows in the generated block below.

Levers kept from the kernel rounds (switches are read once at launch; a lever that is off leaves every gate key
byte-identical; "default" is the state in the code at this commit, and the release defaults are set after the
measurement):

| Lever | Switch | Revision | Exact? | Screening result | Default |
|---|---|---|---|---|---|
| Native int8 encoder GEMM: SmallMGEMM `qtile-1` reads MLX's affine g64 codes (no dequantizing) | `VELLA_PARAKEET_INT8=1` | `+int8-2+smallm-qtile-1` | inexact (tolerant component `int8_gemm`) | Ultra 8 (30 Sep): speed +37.4 % (338.1 → 464.5×), energy −39.2 % (8.343 → 5.069 J/min), memory −506 MB, gate pass, 4 clips changed (ja, ko, zh). v3 8 with BF16 decoder/joint (1 Oct): +35.3 %, −37.6 %, −532 MB, 2 of 21 clips changed | off |
| Native int4 encoder GEMM, group scales applied after the matmul | `VELLA_PARAKEET_INT4=1` | `+int4-2+smallm-qtile-1` | inexact (`int4_gemm`) | Ultra 4 (30 Sep): +44.7 % (346.6 → 501.4×), −40.0 % (8.126 → 4.872 J/min), −553 MB, gate pass vs stock 4, 3 clips changed. v3 4 with BF16 decoder/joint (1 Oct): +35.9 %, −39.6 %, −526 MB, on a tier that stays absent | off |
| Tail block sizing: compiled decoder blocks of 8, 16 or 32 steps sized to the segment's remaining frames (segments need 14–94 decisions; a fixed 32 wastes up to half the last block) | `VELLA_PARAKEET_TAILBLOCK=1` | `+tailblock-1` | exact | Ultra 16 (1 Oct): speed −0.4 %, energy −3.1 %, memory −15 MB, 0 of 21 changed. Borderline, just over the 3 % bar; kept for Ultra only | off |
| Keep MLX's buffer cache between dictation requests (shared dictation service, every dictation model) | `VELLA_DICTATION_KEEP_CACHE=0` restores the per-request clear | — | exact | Ultra 16 (30 Sep): +4.6 % (464.2 → 485.4×), energy +2.4 % (GPU joules equal), memory −36 MB, 21 of 21 identical | on |
| Which modules are quantized: decoder and joint stay BF16 on the 8 and 4 tiers | catalog `floatModules` | recipe `:float=…` | n/a (a recipe) | restores v3's 8 tier (table above) | on |

The integer kernels act only on the quantized tiers; tail block sizing acts on every tier of the model it is set for.

## Rejected levers

Numbers are speed / energy against the arm without the lever, v2-mini, unless noted.

- **int8 encoder under the 16 tier** (30 Sep): −1.4 % / +11.3 % against BF16 with NAX; per-group scale work ties the BF16 tile kernel.
- **Keep-cache on v3 16** (1 Oct): +2.4 % / +2.0 %, +19 MB, no gain. It stays the shared default because it is exact and helps Ultra.
- **Joint window with blank walk** (`VELLA_PARAKEET_JOINTWIN`, exact; 1 Oct): Ultra 16 −1.3 % / +6.1 %, v3 16 +2.5 % / +3.8 %. TDT blanks are rare, so a window step replaces only 1.1–1.7 per-step decisions.
- **Joint read from the quantized codes** (`VELLA_PARAKEET_QJOINT`, exact; 1 Oct): Ultra 8 +1.5 % / −1.1 %, Ultra 4 +3.0 % / +0.2 %, v3 8 +1.1 % / +4.3 %.
- **Tail block sizing on v3 16** (1 Oct): +1.7 % / −2.8 %, under the 3 % bar.
- **Fewer kernels per decoder step** (27 Sep): 7 → 4 kernels per step measured 2.24 against 2.25 ms per 32-step block.
- **16-bit encoder with an 8-bit decoder**: not meaningful; the decoder and joint are 3 % of the parameters and the fast decoder dequantizes them at load, so speed is identical and the saving is 11 MB.
- **Calibrated 4-bit and 8-bit recipes** (mse g32 and g64, bias-aware g64): rejected by Toby on 30 Sep, after the day smokes (built and smoked) and before any A/B or quality run. Plain affine g64 is the only quantization.

Patches for the rejected levers are not published: they stay in the maintainers' lab, outside the source tree and the source archive.

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
a deadline, on five public clips. Exact components (`encoder`, `decoder`, tail blocks) must reproduce stock's tokens, or the whole model runs
stock. Each inexact component (`nax_gemm`, `int8_gemm`, `int4_gemm`) must stay within its tolerance and at most one word
edit in total, or only that component is dropped. A failed verdict is sticky for that model's files, GPU family, macOS build, worker
version and revision. A runtime fallback to stock covers non-finite output.

## Measured figures

<!-- MEASURED_START -->
<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->

Measured 2026-10-01 on Apple M5 Max, macOS 26.6. Accuracy: v2 (239.7 min); speed, energy and peak RAM: v2-quick (22.5 min).

Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "vs Standard" compares the same tier's Optimized cell with its Standard cell. "Offered" is `tiers_offered` in `Resources/models.json`; "Gate vs 16" is the quality gate and presence verdict in `Resources/benchmarks.json`. A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor and every kept module stays at the source dtype.

#### Parakeet v3 Ultra (`parakeet-v3-ultra`)

Gate limits: English ≤ 0.10 pt (noise measured 2026-09-28: 0.02 pt; not remeasured on this build), multilingual mean ≤ 0.10 pt (noise measured 2026-09-28: 0.00 pt; not remeasured on this build).

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | the checkpoint as published | yes | — |
| 8 (int8) | affine group 64 from the bf16 weights; `decoder`, `joint` kept at bf16 (1.8 % of the source checkpoint's weight bytes) | yes | fail; present; gate: multilingual mean +0.23 pt vs 16 (limit 0.10) |
| 4 (int4) | affine group 64 from the bf16 weights; `decoder`, `joint` kept at bf16 (1.8 % of the source checkpoint's weight bytes) | yes | fail; present; gate: multilingual mean +0.79 pt vs 16 (limit 0.10); Swedish +2.37 pt vs 16 (limit 2.0) |

| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | 15.46 | 5.80 | 12.72 | 261.4× | 6.33 | 1796 | — | — |
| 16 (bf16) | Optimized Exact | 15.49 | 5.74 | 12.65 | 474.5× | 4.71 | 1808 | +82 % | −26 % |
| 16 (bf16) | Optimized Fast | 15.51 | 5.79 | 12.73 | 507.1× | 4.58 | 1792 | +94 % | −28 % |
| 8 (int8) | Standard | 15.46 | 5.76 | 12.84 | 244.8× | 8.99 | 1280 | — | — |
| 8 (int8) | Optimized Exact | 15.46 | 5.77 | 12.86 | 369.0× | 8.62 | 1888 | +51 % | −4 % |
| 8 (int8) | Optimized Fast | 15.46 | 5.81 | 12.96 | 515.0× | 5.35 | 1352 | +110 % | −41 % |
| 4 (int4) | Standard | 15.62 | 5.81 | 13.66 | 246.7× | 8.75 | 1024 | — | — |
| 4 (int4) | Optimized Exact | 15.65 | 5.84 | 13.60 | 370.6× | 8.41 | 1640 | +50 % | −4 % |
| 4 (int4) | Optimized Fast | 15.58 | 5.80 | 13.53 | 522.5× | 5.13 | 1094 | +112 % | −41 % |

#### Parakeet v3 (`parakeet-v3`)

Gate limits: English ≤ 0.10 pt (noise measured 2026-09-28: 0.04 pt; not remeasured on this build), multilingual mean ≤ 0.20 pt (noise measured 2026-09-28: 0.15 pt; not remeasured on this build).

| Tier | Runs as | Offered | Gate vs 16 |
|---|---|---|---|
| 16 (bf16) | converted once from the fp32 download | yes | — |
| 8 (int8) | affine group 64 from the bf16 weights; `decoder`, `joint` kept at bf16 (1.8 % of the source checkpoint's weight bytes) | yes | pass; present |
| 4 (int4) | affine group 64 from the bf16 weights; `decoder`, `joint` kept at bf16 (1.8 % of the source checkpoint's weight bytes) | no | fail; absent: 3 clips empty or cut short where 16 had the words |

| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |
|---|---|---|---|---|---|---|---|---|---|
| 16 (bf16) | Standard | 16.37 | 7.84 | 21.30 | 257.7× | 6.35 | 1794 | — | — |
| 16 (bf16) | Optimized Exact | 16.42 | 7.92 | 20.89 | 463.9× | 4.81 | 1777 | +80 % | −24 % |
| 16 (bf16) | Optimized Fast | 16.42 | 7.92 | 20.79 | 494.3× | 4.70 | 1765 | +92 % | −26 % |
| 8 (int8) | Standard | 16.40 | 7.92 | 20.96 | 241.2× | 9.05 | 1279 | — | — |
| 8 (int8) | Optimized Exact | 16.35 | 7.81 | 21.05 | 363.3× | 8.68 | 1883 | +51 % | −4 % |
| 8 (int8) | Optimized Fast | 16.30 | 7.85 | 20.94 | 504.4× | 5.41 | 1342 | +109 % | −40 % |
| 4 (int4) | Standard | 17.02 | 7.68 | 20.48 | 242.3× | 8.84 | 1024 | — | — |
| 4 (int4) | Optimized Exact | 16.90 | 7.69 | 20.68 | 365.0× | 8.49 | 1628 | +51 % | −4 % |
| 4 (int4) | Optimized Fast | 16.95 | 7.69 | 20.77 | 512.3× | 5.20 | 1088 | +111 % | −41 % |
<!-- MEASURED_END -->
