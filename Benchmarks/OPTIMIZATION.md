# Optimize Vella for an Apple chip

Start with the [benchmark recipe](README.md) and the model's existing notes: [Parakeet](../Worker/Sources/MLXAudioSTT/Parakeet/README.md), [Qwen3-ASR](../Worker/Sources/MLXAudioSTT/Qwen3ASR/README.md), [Whisper](../Worker/Sources/MLXAudioSTT/Whisper/README.md), [Nemotron](../Worker/Sources/MLXAudioSTT/NemotronASR/README.md). Those READMEs are the current levers library: implementation names, switches, kept/rejected paths, dated hardware measurements and generated published cells. Use the existing path before inventing another one. M5 Max results do not establish a win on M1–M4 or another M5 configuration.

Ask the user before downloads, long runs, scheduling and opening an issue/PR. Work in a separate checkout, build an isolated candidate, and preserve the installed app. Never benchmark personal recordings. Reuse native downloaded checkpoints; do not download prequantized copies or change the checkpoint to manufacture a speed-up.

## One change, measured

1. Record the chip/GPU cores/RAM/macOS build/power and installed version/build. Run one quick Standard baseline and one candidate at the **same precision**; do not compare int4 to BF16 and call the difference a kernel win. Record actual engine/components/fallbacks. The runner defaults to three warm passes, serially, with whole-clip warmup excluded.
2. Profile before changing code. CPU: `sample PID 5 -file sample.txt` identifies host stalls; compare a working Standard path under the same workload. Split prepare/encoder/decode/postprocessing timers on stderr. GPU: time a short chain of repeated layers with one final `eval`; an `eval` per operation mostly measures synchronization. Removing one operation class in a disposable probe reveals its cost, but that probe's garbage output is never a benchmark result. Use Instruments Metal System Trace for kernel names and compiler spill events.
3. Change the dominant measured cost behind the existing gate/lever system. A/B with the same audio/order/precision and alternate arms rather than running every A before every B. Reuse already measured noise; for a gain near run-to-run variation, run short order-balanced A/B and A/A checks with user consent. Do not spend hours on a one-percent guess.
4. Gate output before crediting speed. Exact components must remain token-exact on all bundled self-test clips. Compare Standard and candidate English WER on full v2: candidate must be within **0.1 percentage point** of stock. Inspect every changed transcript, missing tail/clip, format delta and supported-language delta. Quick is screening only; it cannot establish the full gate. Preserve same streaming session layout and seed for sampling models.
5. Keep only a repeatable practical improvement; report baseline/candidate, date, chip, precision, status, speed spread, WER delta and peak footprint. Update the owning model README with what was kept or rejected and why. Stop when the dominant cost is fixed.

## Existing levers

These are historical screens on M5 Max, not new-chip promises. The linked model README owns final defaults and full-suite qualification; early screens do not override it.

| Model/component | Kept direction | Rejected direction and reason |
|---|---|---|
| Parakeet | Exact fused encoder and compiled TDT; split-K BF16 GEMM in Fast; native affine int8/int4 GEMMs; decoder/joint retained at BF16 in quantized tiers | Int8 encoder under 16-bit: slower and more energy; joint-window and quantized-joint screens too small; a different accumulation order can cross decoder ties |
| Qwen3-ASR | Pipeline decode so CPU work overlaps GPU; preserve the FP32 audio encoder's numerics | Compiled low-bit step and tower GEMM screens below meaningful gain; calibrated int4 failed quality and changes the quantization recipe |
| Whisper | Mixed fp16 encoder + affine int8 decoder; exact shape-gated kernels documented in its notes | Int8 encoder no faster than fp16; K/V preallocation, bias/GELU folding and compiled step lost on the profile |
| Nemotron | Reuse buffer cache across 100-ms packets; batched joint output projection; qualify memory over long streams | Prompt split/one-hot cache ineffective; fused mel gain small; relaxed atomics cannot order a cross-threadgroup layer-normalization epilogue |
| Shared | Drain per-request autorelease pools; bound caches; one worker binary with streaming alias | Clearing caches after every request adds allocation work; a lifetime peak alone cannot prove a leak |

Quantization remains native bf16/fp16 plus plain MLX affine group-64 int8/int4 derived locally. Do not calibrate, search/refit scales, quantize an already quantized source or silently cast BF16 to FP16. Kernel dispatch must gate every dtype (including bias), geometry, stride and GPU feature family it assumes.

## Put a path behind FastPathGate

Read [FastPathGate.swift](../Worker/Sources/MLXAudioSTT/Gate/FastPathGate.swift) and a working component in the same model before editing. Register the lever in [EnvironmentSwitch.swift](../Packages/VellaWire/Sources/VellaWire/EnvironmentSwitch.swift), the owning model runtime and gate revision. Use a separate component key where a failure can disable that component alone; retain working Standard. Include effective lever set, checkpoint/recipe identity, GPU feature family, OS/build and app/worker revision in the existing qualification identity. Bump the affected revision when kernel numerics or dispatch changes.

Exact paths qualify token-exact on the bundled self-test clips. Existing inexact components have their own finite-output/RMS and text-edit tolerances; an inexact path belongs only in Fast and must still pass the full task-quality gate. Do not weaken a self-test just to show a win. The app reports active components and fallback reasons; check those fields and, when needed, sample the worker or log the first call per kernel/shape. Seeing a wrapper frame or an environment switch only proves the wrapper was visited, not that its guard used the kernel.

Build the candidate without replacing or registering the installed app:

```sh
VELLA_APP_PATH=/tmp/Vella-candidate.app VELLA_REGISTER_APP=0 VELLA_SIGN_IDENTITY=- scripts/build.sh
```

Use `run.py --app /tmp/Vella-candidate.app` after user consent. Compare a source-built Standard control and candidate from the same final build/toolchain; the CLI `--path/--mode` options select qualified recipes. Do not inherit an experiment override silently. For a new lever without a public selection yet, exercise it in a narrow owned probe and include its effective status and diff before adding it to the public runner.

Score files and gate:

```sh
python3 Benchmarks/scorer/Benchmarks/v2/scoring.py Benchmarks/suites/v2/manifest.json standard-pass.json --support Benchmarks/scorer/support.json --bootstrap 0 --output standard-score.json
python3 Benchmarks/scorer/Benchmarks/v2/scoring.py Benchmarks/suites/v2/manifest.json candidate-pass.json --support Benchmarks/scorer/support.json --bootstrap 0 --output candidate-score.json
python3 Benchmarks/gate.py standard-score.json candidate-score.json --standard-pass standard-pass.json --candidate-pass candidate-pass.json
```

Pass files contain exactly one hypothesis for every manifest clip. `gate.py` compares the pinned scorer/suite/model identities and English/format delta, lost clips/tails and supported-language mean/per-language gates (the published family tolerance, with +2 points maximum for languages having at least 5 audio minutes). Self-test token parity, error-free execution, same precision/seed/session and actual dispatch remain required evidence in the PR; a numeric gate alone cannot establish those.

## Traps worth avoiding

- Swift protocol-extension members dispatch statically unless they are protocol requirements. Status can claim `mlx` while an optimized implementation actually ran; follow the current runtime protocol.
- MLX compiled closures must take weights as inputs. Capturing weights can retain an unloaded model; compile caches can retrace per thread/shape. Compile only the measured hot graph.
- BF16 rounding points matter. Fused sigmoid/BatchNorm need the stock operation order and rounding; one final cast is not equivalent. Probe individual operations before integrating Swift.
- GEMM accumulation order can change near-tie tokens even with tiny error. A second valid split order/tile shape tests whether a self-test pass has margin.
- Compile custom Metal offline first; Swift MLX compilation failures can abort a worker. Preserve MLX's precise-math flags. M5 matrix-unit features need an explicit availability guard and Standard fallback.
- Unified-memory footprint includes GPU allocations; RSS and weight size are different metrics. Sample `footprint -p PID`/`vmmap` categories when investigating growth. Wrap every long-lived JSON/file-read loop in `autoreleasepool`.
- Worker stdout contains pushed status lines. Match response IDs, retain stderr privately and bound request deadlines. Never let a shifted response list produce plausible scores.
- Inexact kernels must stay finite for valid extreme input, including final split-K reduction. Check guard and fallback paths as well as a forced kernel; numerical exceptional cases may need float64 truth rather than equality to overflowing stock.
