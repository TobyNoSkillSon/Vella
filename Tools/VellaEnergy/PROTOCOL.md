# Vella energy protocol

`vella-energy` is an independent SwiftPM executable (no root, no dependencies); it `dlopen`s private `libIOReport` and brackets Energy Model counters with two snapshots. Build: `xcrun swift build --package-path Tools/VellaEnergy -c release`. Executable: `Tools/VellaEnergy/.build/release/vella-energy`. It does **not** launch or interact with Vella.

On the measured M5 Max / macOS 26.6, validated selected channels are `CPU Energy` (mJ), `GPU Energy` (nJ), `ANE` (mJ), `DRAM` (mJ). Convert delta to joules using each channel's observed unit. Other devices may expose different names; absent, negative-delta or unknown-unit components are `null`, never fabricated zero. ANE zero is a measured delta only, not proof of accelerator placement. `cpu+gpu+ane` is subsystem energy, **not whole-machine energy**; DRAM is reported separately. Never add a system estimate to these counters. IOReport is private and system-wide, thus concurrently running programs contaminate the reading. No SMC whole-device counter is supplied.

## Commands

- Standby: `vella-energy sample --interval-ms 600000 --pid <installed-Vella-pid> --require-idle > standby-raw.json`. PID accounting uses `proc_pid_rusage(RUSAGE_INFO_V6)`; cumulative task user/system time and wakeup counters are differenced across the bracket, along with task CPU `ri_energy_nj` (XNU Recount estimate). `ri_billed_energy` is *cross-task bank billing*, not own task energy; its raw difference is diagnostic only. Physical footprint is a point-in-time value, lifetime peak is not necessarily attained during this window. The PID start-abstime is compared to guard against PID reuse. If inaccessible/exited, fail or mark unavailable. Same-user process access is required. Recheck `~/Library/Application Support/Vella/dictation-status.json` and report recording overlaps; never touch the installed bundle or its settings.
- Arbitrary child: `vella-energy measure --baseline-ms 10000 -- /absolute/command args... > energy.json`. Idle baseline **precedes** child, and its joules scale by `workSeconds / baselineSeconds`; negatives remain negative. Wall time includes launch and exit. Exit code is in JSON (nonzero is not a successful task).
- Resident-worker two-bracket mode: `vella-energy measure --handshake --require-idle --baseline-ms 10000 -- /absolute/command args...`. Child writes `READY\n` after a cold model load/first request, waits for `GO\n` on stdin, then runs until exit. The output contains separate preload-idle → cold-start, then loaded-idle → warm-work brackets and corresponding idle-subtracted component joules. Warm bracket includes worker teardown and child exit; compare with the driver's narrower inference duration. The two baselines are each scaled to their respective work elapsed time, with no clamping. The baseline should be long enough for its noise floor, and no other GPU work should run.

## Parakeet Q4 reproducibility

Use **public** `Resources/Benchmarks/english-formatted-20m-v1/manifest.json` (144 clips, nominal 1215.44 audio seconds). In a scratch directory (not inside the bundle), run the installed Vella Python solely as an interpreter, installing nothing. `bench_python.py prepare --suite <suite-absolute> --wav-dir <scratch>/wavs` verifies all 144 FLAC hashes and converts using an existing `ffmpeg` executable to strict mono/16-kHz/16-bit WAV (the sole 32.88-second clip splits into 30 + 2.88 seconds, yielding 145 requests per 144-clip pass) accepted by `Resources/inference_worker.py`; conversion is outside the measured bracket. The worker is launched through the pinned runtime Python with `-B`, offline environment, and `sandbox-exec -p '(version 1) (allow default) (deny network*)'` around the driver for the run. Example after verifying `dictation-status.json` phase `idle`:

```sh
PY="$HOME/Library/Application Support/Vella/Runtimes/mlx-audio-0.5.1-mlx-0.32.2-8d5faf2609fb-python-3.14/bin/python"
MODEL="$HOME/Library/Application Support/Vella/Models/parakeet-tdt-0.6b-v3-mlx-4bit"
SUITE="$PWD/Resources/Benchmarks/english-formatted-20m-v1"
QA="$PWD/.build/qa/native-runtime/vn-energy"
"$PY" -B Tools/VellaEnergy/bench_python.py prepare --suite "$SUITE" --wav-dir "$QA/wavs"
Tools/VellaEnergy/.build/release/vella-energy measure --handshake --require-idle --baseline-ms 10000 -- \
  /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$PY" -B Tools/VellaEnergy/bench_python.py run --suite "$SUITE" \
  --wav-dir "$QA/wavs" --model "$MODEL" --worker "$PWD/Resources/inference_worker.py" \
  --minimum-seconds 60 --result "$QA/python-run.json" > "$QA/python-energy.json"
```

The driver checks Vella's idle phase before launching the worker **and before each clip**. It sends one cold first request, signals READY, then repeats **complete** 144-clip corpus passes until warm elapsed ≥60 s, always synchronizing via the inference worker's JSON response. `python-run.json` records cold worker metrics, warm audio seconds, pass count, and aggregate transcript hash; `python-energy.json` records independent cold and warm counter brackets. If the app starts recording, abort and discard the run. Calculate `warmIdleSubtractedJoules[component] / (warmAudioSeconds/60)` (CPU+GPU+ANE total separately; DRAM separately). Inspect noise floor and cold-start separately. For a robust comparison, alternate at least five native/Python warmed runs, matching host, AC power, suite, model/weights, decoding, background workload, and output parity; show spread rather than one point. This single run is a baseline, not publication-grade evidence.
