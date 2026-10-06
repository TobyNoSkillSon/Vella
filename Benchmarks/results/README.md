# Contribute one result

One JSON per chip/model/cell under this directory, named `YYYY-MM-DD-chip-model-precision-path-mode-quick|full.json`. Start with the runner's `result.json`; [result.example.json](../result.example.json) is synthetic format guidance, never evidence. No personal recordings, private logs, support directories, weights or upstream audio go into a PR.

The record includes chip, GPU core count, RAM bytes, macOS version/build, power source, Vella version/build, model/checkpoint revision, precision, requested Standard/Optimized and Exact/Fast, actual engine/components/fallbacks from status, suite ID/version/hash, WER percent, speed × real time, worker peak physical footprint in decimal MB, three or more warm passes, warmup and machine-idle condition. Quick quality is always labelled `estimate`. API wall speed includes decode, segmentation and response work; it is not the published helper-only inference speed.

For an optimization, include the baseline and candidate records, all changed transcripts, profile, diff and gate output. Record both source commits and worker hashes. Run the full suite before claiming the full-quality gate passed. Numbers alone can be contributed for one model; they do not automatically replace the reference table. Maintainers review hardware, protocol, quality and claims by hand.

## M5 Max maintainer baselines

Measured 6 October 2026 using the published Vella 2.0.1, build 36, on a 40-core M5 Max with 128 GiB RAM, macOS 27.0.1 and AC power. The Mac was in active use (`machine_idle: no`); speeds varied across passes. Each record retains all three passes and actual engine status. No energy or temperature measurement was taken; `pmset` reported no recorded thermal/performance warnings before or after the runs.

- [Ultra BF16 Optimized Fast, quick estimate](2026-10-06-apple-m5-max-parakeet-v3-ultra-bf16-optimized-fast-quick.json): installed-app API.
- [Ultra BF16 Optimized Fast, full](2026-10-06-apple-m5-max-parakeet-v3-ultra-bf16-optimized-fast-full.json): installed-app API; English WER rounds to the published 15.51%. Full-suite peak RAM includes allocations outside the published quick performance suite.
- [Nemotron BF16 Optimized Fast, quick estimate](2026-10-06-apple-m5-max-nemotron-3.5-streaming-0.6b-bf16-optimized-fast-quick.json): shipped streaming helper, with the packet/gap/session layout recorded in the JSON.

The other five dictation families lacked installed native checkpoints and were skipped; no model weights were downloaded. Compare results only within the same suite, transport and cell, accounting for machine conditions. These records do not replace the dated helper-timer figures in the app table.

Before proposing a PR:

```sh
Benchmarks/.venv/bin/python Benchmarks/check-result.py Benchmarks/runs/ultra-quick/result.json
```

Inspect that file yourself. Copy only the shareable result JSON here (retain pass/score files locally for review); describe whether the Mac was idle and whether power/thermal conditions changed. Ask the user before opening the PR at https://github.com/TobyNoSkillSon/Vella. A quick result must say **estimate** in the PR title/body. Measurement permission does not authorize publishing.

For example, slug `Apple M3 Pro` as `apple-m3-pro` (lowercase, spaces → hyphens). After inspecting the result and receiving publication consent:

```sh
git switch -c results/apple-m3-pro-ultra-quick
cp Benchmarks/runs/ultra-quick/result.json Benchmarks/results/2026-10-06-apple-m3-pro-parakeet-v3-ultra-bf16-optimized-fast-quick.json
git add Benchmarks/results/2026-10-06-apple-m3-pro-parakeet-v3-ultra-bf16-optimized-fast-quick.json
git commit -m "Add Apple M3 Pro Ultra quick estimate"
git push -u origin results/apple-m3-pro-ultra-quick
gh pr create --repo TobyNoSkillSon/Vella --base main --title "Apple M3 Pro: Ultra quick estimate" --body "Quick suite estimate; bf16 Optimized Fast. See JSON for actual engine/fallbacks, power and machine-idle conditions. No full-suite claim. Agent: NAME/MODEL."
```

Use your actual date, chip, cell, agent and conditions; the filename and title above are examples. A fork contributor pushes to their fork and selects that head in `gh pr create`. Include baseline/candidate and gate evidence for an optimization. Keep `support/`, logs, audio and model files private.

## Optional energy

Energy is absent unless the user consents to admin `powermetrics` and the following protocol. Never enter 0, `null`, a speed-derived estimate or a battery percentage for missing energy. Speed/WER/RAM-only contributions are welcome.

1. Load and warm the same isolated model. Keep it loaded throughout. Ask for admin consent; have the user's authorized shell start `sudo powermetrics --samplers cpu_power,gpu_power -i 100 --format plist -o power.plist`. Keep the raw file local; do not collect personal recordings.
2. Record at least 10 seconds of loaded idle before the warm pass, then its UTC start/end, then at least 10 seconds of loaded idle after it. Run at least three brackets. CPU + GPU power is whole-machine power in watts, not per-process energy; stop when other work contaminates the bracket.
3. Integrate each sample's CPU + GPU watts over its actual elapsed duration within the warm interval. Subtract the mean of the two idle brackets × warm seconds. Divide net joules by suite audio minutes. Report the median of the three clean brackets and their spread. If net energy is nonpositive or the brackets are noisy, omit energy and explain why. This is a contribution protocol, distinct from the published IOReport helper protocol.
4. Add `metrics.energy_j_per_audio_minute` only with `protocol.energy`: `method: powermetrics-cpu-gpu-idle-subtracted-v1`, `admin_consent: true`, `interval_ms: 100`, `idle_before_seconds`, `idle_after_seconds`, `idle_watts`, `warm_start_utc`, `warm_end_utc`, `raw_sha256` and `notes` with bracket values, arithmetic, thermal/power conditions and contamination checks. Retain the raw samples and time receipts for manual review. The runner does not invoke sudo or fabricate energy.
