# Benchmark and optimize Vella on your Mac

Coding agents start here. Measure one installed model, then propose a result or a chip-specific improvement for manual review. Ask the user before downloads, long runs, scheduling, or opening an issue/PR. Never include personal recordings. A quick result is an **estimate**, not a replacement for the published full-suite WER.

## Run one model

1. Install Vella using the repository's `scripts/install.sh`. Ask before Get if the native checkpoint is missing. Default: `parakeet-v3-ultra`, `bf16`, `Optimized`, `Fast`. `vella models --json` lists sources, download sizes and available cells. No model download happens in this kit.
2. Make a tooling environment (Python 3.12+; it is not Vella's inference runtime):
   ```sh
   python3 -m venv Benchmarks/.venv
   Benchmarks/.venv/bin/pip install -r Benchmarks/requirements.txt
   (cd Benchmarks && shasum -a 256 -c SHA256SUMS)
   ```
   If dependencies are already available in a prepared tooling environment, reuse it. With uv and cached wheels, `uv venv --python python3.12 Benchmarks/.venv && uv pip install --offline --python Benchmarks/.venv/bin/python -r Benchmarks/requirements.txt` needs no network.
3. After audio-download consent:
   ```sh
   Benchmarks/.venv/bin/python Benchmarks/fetch.py --suite quick --yes
   ```
4. With the user's run consent, use a quiet Mac, no other inference, and stable power. Run serially:
   ```sh
   Benchmarks/.venv/bin/python Benchmarks/run.py --app "$HOME/Applications/Vella.app" --machine-idle yes --out Benchmarks/runs/ultra-quick
   ```
   A DMG install uses `/Applications/Vella.app`. The runner starts a separate instance of that installed app with a fresh support directory, reads only the native installed-model registry entry, warms one whole clip, then measures three serial passes through its real API. It creates derived tiers only in its isolated profile. Your usual Vella settings, history and recordings are untouched. Quit other inference yourself; this kit never stops another app. Use `--dry-run` to verify inputs without launching, loading or transcribing.
5. Check and inspect the result, then ask before submitting:
   ```sh
   python3 Benchmarks/check-result.py Benchmarks/runs/ultra-quick/result.json
   ```
   Read [results/README.md](results/README.md) for the JSON and PR recipe. Keep `support/` and `app.log` private.

For another cell add `--model ID --precision bf16|fp16|int8|int4 --path Standard|Optimized --mode Exact|Fast`. For full quality, fetch and run with `--suite full`; retain all clips. `--audio-root PATH` reuses an existing verified audio directory without copying it. `--models-from PATH` reads another installed registry, never its recordings or configuration. The runner refuses inherited experiment switches; a source-built candidate is selected through `--app`.

**Nemotron:** 2.0.0 exposes no streaming transcription API. [streaming.py](streaming.py) drives the installed app's shipped streaming helper, using 100-ms packets and a fixed 1.2-second silence between clips, as the published measurement did. It is labelled `shipped-streaming-helper`, not end-to-end app/API performance. Read its `--help` and the model [notes](../Worker/Sources/MLXAudioSTT/NemotronASR/README.md); compare Standard and candidate with identical session layout. The kit does not automate microphone or UI recording.

## Suites and audio

| Frozen suite | Clips | Audio minutes | Use |
|---|---:|---:|---|
| `vella-v2-quick` | 122 | 22.547 | Warm speed and quick quality estimate |
| `vella-v2` | 797 | 239.655 | Full quality and optimization acceptance |

Quick reuses the published subset unchanged, including its long-form call. It is 22.5 minutes of audio, not a promise of 15 minutes of wall time on every chip/model. Three warm passes process 67.6 audio minutes. Full processes 719.0 audio minutes across three passes. The manifest version `2.0.0-dev` is the frozen original identifier; its byte hash, not a renamed version, pins the published inputs. No reselection or missing-clip substitution is allowed.

No audio is committed, no LFS is used and no audio release is required. The clone contains the exact references, source revisions, extraction recipes and per-file/PCM hashes. [DATASETS.md](DATASETS.md) labels every dataset, licence and extracted size. Fetch audio directly from the named pinned upstreams; dataset terms remain theirs. This avoids redistributing recordings whose rights are unclear or restrictive. The extracted full suite is about 218 MB; upstream containers may need over 6 GB temporarily. Quick fetches only its clips, though upstream containers can still be large. Ask before downloads and allow that space; `.cache/` and `.data/` are ignored. A changed or unavailable upstream is a reported failure, never permission to substitute audio or adjust a hash.

`fetch.py --verify-only` checks sample rate, mono layout, sample count and SHA-256 of little-endian PCM16. Reconstruction uses the original decoder, channel selection and soxr VHQ resampling. FLAC encoder bytes can differ; PCM identity cannot. The untouched scorer and formatting scorer are pinned in `SHA256SUMS`. English WER pools word edit counts; the scorer's `rate` is a fraction, whereas result JSON `wer_percent` is percent. [Methods](../docs/BENCHMARKS.md) defines all normalization and metrics.

## Optimize and compare

Read [OPTIMIZATION.md](OPTIMIZATION.md). Preserve a Standard fallback and prove the requested and actual engine from status. Quick A/B screens a change; full quality is required before claiming an accepted optimization. Results are reviewed by maintainers by hand. There is no scheduled runner, upload command, validator service or automatic merge.
