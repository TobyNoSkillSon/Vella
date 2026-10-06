# Contribute one result

One JSON per chip/model/cell under this directory, named `YYYY-MM-DD-chip-model-precision-path-mode-quick|full.json`. Start with the runner's `result.json`; [result.example.json](../result.example.json) is synthetic format guidance, never evidence. No personal recordings, private logs, support directories, weights or upstream audio go into a PR.

The record includes chip, GPU core count, RAM bytes, macOS version/build, power source, Vella version/build, model/checkpoint revision, precision, requested Standard/Optimized and Exact/Fast, actual engine/components/fallbacks from status, suite ID/version/hash, WER percent, speed × real time, worker peak physical footprint in decimal MB, three or more warm passes, warmup and machine-idle condition. Quick quality is always labelled `estimate`. API wall speed includes decode, segmentation and response work; it is not the published helper-only inference speed.

For an optimization, include the baseline and candidate records, all changed transcripts, profile, diff and gate output. Record both source commits and worker hashes. Run the full suite before claiming the full-quality gate passed. Numbers alone can be contributed for one model; they do not automatically replace the reference table. Maintainers review hardware, protocol, quality and claims by hand.

Before proposing a PR:

```sh
python3 Benchmarks/check-result.py Benchmarks/runs/ultra-quick/result.json
```

Inspect that file yourself. Copy only the shareable result JSON here (retain pass/score files locally for review); describe whether the Mac was idle and whether power/thermal conditions changed. Ask the user before opening the PR at https://github.com/TobyNoSkillSon/Vella. A quick result must say **estimate** in the PR title/body. Measurement permission does not authorize publishing.

## Optional energy

Energy is absent unless the user consents to admin `powermetrics` and the following protocol. Never enter 0, `null`, a speed-derived estimate or a battery percentage for missing energy. Speed/WER/RAM-only contributions are welcome.

1. Load and warm the same isolated model. Keep it loaded throughout. Ask for admin consent; have the user's authorized shell start `sudo powermetrics --samplers cpu_power,gpu_power -i 100 --format plist -o power.plist`. Keep the raw file local; do not collect personal recordings.
2. Record at least 10 seconds of loaded idle before the warm pass, then its UTC start/end, then at least 10 seconds of loaded idle after it. Run at least three brackets. CPU + GPU power is whole-machine power in watts, not per-process energy; stop when other work contaminates the bracket.
3. Integrate each sample's CPU + GPU watts over its actual elapsed duration within the warm interval. Subtract the mean of the two idle brackets × warm seconds. Divide net joules by suite audio minutes. Report the median of the three clean brackets and their spread. If net energy is nonpositive or the brackets are noisy, omit energy and explain why. This is a contribution protocol, distinct from the published IOReport helper protocol.
4. Add `metrics.energy_j_per_audio_minute` only with `protocol.energy`: `method: powermetrics-cpu-gpu-idle-subtracted-v1`, `admin_consent: true`, `interval_ms: 100`, `idle_before_seconds`, `idle_after_seconds`, `idle_watts`, `warm_start_utc`, `warm_end_utc`, `raw_sha256` and `notes` with bracket values, arithmetic, thermal/power conditions and contamination checks. Retain the raw samples and time receipts for manual review. The runner does not invoke sudo or fabricate energy.
