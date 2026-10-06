# Benchmark and optimize Vella on your Mac

Coding agents start here. Measure one installed model, then propose a result or a chip-specific improvement for manual review. Ask the user before downloads, long runs, scheduling, or opening an issue/PR. Never include personal recordings. A quick result is an **estimate**, not a replacement for the published full-suite WER.

Reference text is third-party data with mixed licences, separate from Vella’s MIT licence. Polish TEDx and MediaSpeech references are fetched into the ignored local cache; other references retain their BY, BY-SA, Apache or CDLA terms and attribution. Read [DATASETS.md](DATASETS.md) before downloading, using or sharing data.

## Run one model

1. Install Vella using the repository's `scripts/install.sh`. Ask before Get if the native checkpoint is missing. Default: `parakeet-v3-ultra`, `bf16`, `Optimized`, `Fast`. `vella models --json` lists sources, download sizes and available cells. No model download happens in this kit.
2. Make a tooling environment. Check the interpreter first:
   ```sh
   python3 -c 'import sys; print(sys.version); raise SystemExit(0 if sys.version_info >= (3, 12) else "Python 3.12+ required; use uv below")'
   ```
   The Command Line Tools `python3` can be 3.9; it cannot install these pinned dependencies. Prefer uv's explicit Python 3.12 environment: it avoids changing the system Python and does not require Homebrew. If uv is missing, after tooling-download consent install it using https://docs.astral.sh/uv/getting-started/installation/:
   ```sh
   curl -LsSf https://astral.sh/uv/install.sh | sh
   "$HOME/.local/bin/uv" venv --python 3.12 Benchmarks/.venv
   "$HOME/.local/bin/uv" pip install --python Benchmarks/.venv/bin/python -r Benchmarks/requirements.txt
   Benchmarks/.venv/bin/python -c 'import sys; assert sys.version_info >= (3, 12); print(sys.version)'
   (cd Benchmarks && shasum -a 256 -c SHA256SUMS)
   ```
   If uv is already on PATH, use `uv` instead of its full path. uv can download Python 3.12 if missing (https://docs.astral.sh/uv/guides/install-python/); obtain consent first. Python is only for these tools, not Vella's inference runtime. Reuse a prepared environment when available. With a cached interpreter and wheels, `uv venv --offline --python 3.12 Benchmarks/.venv` and `uv pip install --offline --python Benchmarks/.venv/bin/python -r Benchmarks/requirements.txt` need no network.
3. After upstream audio/reference-download consent:
   ```sh
   Benchmarks/.venv/bin/python Benchmarks/fetch.py --suite quick --yes
   ```
4. With the user's run consent, use a quiet Mac, no other inference, and stable power. Run serially:
   ```sh
   Benchmarks/.venv/bin/python Benchmarks/run.py --app "$HOME/Applications/Vella.app" --machine-idle unknown --out Benchmarks/runs/ultra-quick
   ```
   Set `--machine-idle yes|no|unknown` honestly: `yes` only when you observed a quiet machine throughout; record other work or uncertainty. Use a fresh `--out` for every model/cell/run; existing folders are refused and preserved.

   A DMG install uses `/Applications/Vella.app`. The runner starts a separate instance of that installed app with a fresh support/home directory and its existing headless API mode (no extra menu, shortcuts or update checks), reads only the native installed-model registry entry, warms one whole clip, then measures three serial passes through its real API. It creates derived tiers only in its isolated profile. Your usual Vella settings, history and recordings are untouched. Quit other inference yourself; this kit never stops another app. Use `--dry-run` to verify inputs without launching, loading or transcribing.
5. Check and inspect the result, then ask before submitting:
   ```sh
   Benchmarks/.venv/bin/python Benchmarks/check-result.py Benchmarks/runs/ultra-quick/result.json
   ```
   Read [results/README.md](results/README.md) for the JSON and PR recipe. Keep `support/` and `app.log` private.

For another cell add `--model ID --precision bf16|fp16|int8|int4 --path Standard|Optimized --mode Exact|Fast`. For full quality, fetch and run with `--suite full`; retain all clips. `--audio-root PATH` reuses an existing verified audio directory without copying it. `--models-from PATH` accepts an installed `models-installed.json` file or its support directory, reading only the registry. The runner refuses inherited experiment switches; a source-built candidate is selected through `--app`.

**Nemotron:** 2.0.0 exposes no streaming transcription API. [streaming.py](streaming.py) drives the installed app's shipped streaming helper, using 100-ms packets and a fixed 1.2-second silence between clips, as the published measurement did. It finishes a separate warm-up stream before timing; every measured pass starts a fresh session while reusing the loaded model. It is labelled `shipped-streaming-helper`, not end-to-end app/API performance. Read its `--help` and the model [notes](../Worker/Sources/MLXAudioSTT/NemotronASR/README.md); compare Standard and candidate with identical session layout. The kit does not automate microphone or UI recording.

## Numbers for each model

Inspect `vella models --json` before running: its `data` array includes each family's `id`, `mode`, `dtype`, available `cells`, and `download` size/source/revision. Choose a valid precision per family (`bf16` or `fp16` for native; `int8`/`int4` for derived tiers). Missing weights require the user's consent for that model's download size; only then run `vella get ID --yes`. Get downloads the native checkpoint and may derive the selected precision; it does not grant benchmark or publication consent.

Run dictation families serially, with a fresh output folder per model. This prints the IDs without loading anything:

```sh
vella models --json | Benchmarks/.venv/bin/python -c 'import json,sys; print("\n".join(m["id"] for m in json.load(sys.stdin)["data"] if m["mode"] == "Dictation"))'
```

For each ID, run the one-model command with `--model ID --precision PRECISION --out Benchmarks/runs/ID-PRECISION-quick-1`, replacing the placeholders. Repeat for each requested cell; never reuse the default Ultra folder. Nemotron uses the separate helper lane below.

After Get, find Nemotron's native installed checkpoint and revision by joining the app catalog to the registry (this only reads files):

```sh
Benchmarks/.venv/bin/python - "$HOME/Applications/Vella.app" <<'PYTHON'
import json, sys
from pathlib import Path
app = Path(sys.argv[1])  # use /Applications/Vella.app for a DMG install
catalog = json.loads((app / "Contents/Resources/models.json").read_text())
f = next(f for f in catalog["families"] if f["id"] == "nemotron-3.5-streaming-0.6b")
v = next(v for v in f["variants"].values() if not v.get("derivedFrom"))
registry = json.loads((Path.home() / "Library/Application Support/Vella/models-installed.json").read_text())
entry = registry[v["id"]]
print("--model-path", entry["path"])
print("--checkpoint-revision", entry["revision"])
print("native precision:", f["native"])
PYTHON
```

Pass those exact values to `streaming.py --model-path PATH --checkpoint-revision REVISION`, with `--app`, `--precision bf16`, `--suite quick`, an honest `--machine-idle`, and a fresh `--out`. Native Nemotron is BF16. For a derived tier, use its verified registry path/manifest and matching precision; do not label a native checkpoint int8/int4. Never submit checkpoint paths in the results JSON.

Kit API speed measures the entire serial API request, including file decode, app segmentation and HTTP response work. Published README/table speeds use the helper timer and exclude file preparation and the app/HTTP layer. **Compare kit speeds with kit speeds**, on the same transport, suite, precision and conditions; do not rank an API result against the published helper figure. The maintainer's [M5 Max v2.0.1 kit baselines](results/README.md#m5-max-maintainer-baselines) include Ultra quick/full and Nemotron quick. Nemotron's helper lane is separate again because of its packet/gap layout.

## Suites and audio

| Frozen suite | Clips | Audio minutes | Use |
|---|---:|---:|---|
| `vella-v2-quick` | 122 | 22.547 | Warm speed and quick quality estimate |
| `vella-v2` | 797 | 239.655 | Full quality and optimization acceptance |

Quick reuses the published subset unchanged, including its long-form call. It is 22.5 minutes of audio, not a promise of 15 minutes of wall time on every chip/model. Three warm passes process 67.6 audio minutes. Full processes 719.0 audio minutes across three passes. The manifest version `2.0.0-dev` is the frozen original identifier. The licence cleanup changes manifest bytes, replacing restrictive reference text with SHA-256 hashes; `publishedIdentity` preserves the original manifest/scorer hashes in historical results. New runs record the current hashes. Clip IDs/order, extraction origins, audio identities, reference bytes and scoring rules are unchanged. No reselection or missing-clip substitution is allowed.

No benchmark audio is committed, no LFS is used and no benchmark audio release is required. Six separately licensed LibriSpeech self-test/calibration clips ship with the app. The kit contains source revisions, extraction recipes, per-file/PCM hashes, permitted reference text and hashes for locally fetched references. [DATASETS.md](DATASETS.md) lists each dataset's attribution, licence, text policy and audio policy. Fetch from the named pinned upstreams; source terms still govern local use. TEDx remains noncommercial; do not share its adapted text or restrictive/unclear-rights caches.

The extracted full suite is about 218 MB; upstream containers may need over 6 GB temporarily. Quick fetches only its clips, though upstream containers can still be large. Ask before downloads and allow that space; `.cache/` and `.data/` are ignored. A changed or unavailable upstream is a reported failure, never permission to substitute audio, text or adjust a hash.

To fetch/check only reference text, without audio or a model run:

```sh
Benchmarks/.venv/bin/python Benchmarks/fetch.py --suite full --references-only --yes
```

Reference strings are cleaned with the original builder's Unicode NFC and whitespace collapse. Both `reference` and any separately published `lexicalReference` are verified by SHA-256 of their UTF-8 bytes before use. Caches live in `--audio-root/references` (default `.data/references`). Runners, the scorer and the gate read verified caches without network access and fail if a reference is missing or changed. For an alternate cache location, pass `--references-root PATH` to the standalone scorer/gate. These checks do not run a model or repeat published measurements.

`fetch.py --verify-only` checks sample rate, mono layout, sample count and SHA-256 of little-endian PCM16. Reconstruction uses the original decoder, channel selection and soxr VHQ resampling. FLAC encoder bytes can differ; PCM identity cannot. The scorer, reference loader/fetchers and unchanged formatting scorer are pinned in `SHA256SUMS`. English WER pools word edit counts; the scorer's `rate` is a fraction, whereas result JSON `wer_percent` is percent. [Methods](../docs/BENCHMARKS.md) defines all normalization and metrics.

## Optimize and compare

Read [OPTIMIZATION.md](OPTIMIZATION.md). Preserve a Standard fallback and prove the requested and actual engine from status. Quick A/B screens a change; full quality is required before claiming an accepted optimization. Results are reviewed by maintainers by hand. There is no scheduled runner, upload command, validator service or automatic merge.
