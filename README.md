# Vella

<p align="center">
  <img src="docs/images/models-current.png" alt="Vella Models table with Dictation and Streaming sections, six precision cells per model, Exact/Fast, Get/Load/Unload, and final M5 Max benchmark figures" width="904">
</p>

Offline dictation and transcription for Mac: local Whisper, Parakeet and Qwen speech-to-text, tuned for Apple Silicon. Scripts and coding agents get an OpenAI-compatible local API: `POST /v1/audio/transcriptions`.

Press **Control + Command + N**, speak, press it again: Vella transcribes on your Mac and pastes the text where you were typing. In Streaming mode the words appear as you speak. Audio and text stay on the Mac.

```sh
curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash
```

Apple Silicon, macOS 26 or newer. No Xcode, Python or developer account.

[Models](#models) · [Install](#install) · [Using it](#using-it) · [For your agent](#for-your-agent) · [Privacy](#privacy) · [User guide](docs/USAGE.md) · [Sponsor](https://github.com/sponsors/TobyNoSkillSon)

## Models

Seven open models; nothing downloads until you choose **Get**. Four starting points:

<!-- RELEASE_SHORT_TABLE_START -->

Measured 1–3 October 2026 on Apple M5 Max, macOS 26.6. English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately. Speed, energy and peak RAM: v2-quick (22.5 min).

| Model | Use it for | Tier / path | English WER % | Speed | J / audio min | Peak RAM MB |
|---|---|---|---|---|---|---|
| Parakeet v3 Ultra | Dictation in 25 European languages | bf16 · Optimized Fast | 15.51 | 507.1× | 4.58 | 1792 |
| Whisper large-v3 turbo | About 100 languages, faster Whisper | fp16 · Optimized Fast | 16.57 | 113.7× | 37.18 | 2522 |
| Whisper large-v3 | About 100 languages | fp16 · Optimized Fast | 17.06 | 34.8× | 83.50 | 3915 |
| Qwen3 ASR 1.7B | 30 languages, including Chinese, Japanese and Korean | bf16 · Optimized Fast | 15.00 | 29.6× | 72.73 | 5118 |

<!-- RELEASE_SHORT_TABLE_END -->

Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far

Only the checkpoint's native 16-bit weights are downloaded; `int8` and `int4` are made on your Mac from them. The table shows the dtype actually running (`bf16`/`fp16`, `int8`, `int4`). Choose Standard or Optimized; Optimized has Exact and Fast recipes. Missing figures show `—`, never a sibling model's score. Models and weights retain their own licences in [`Resources/models.json`](Resources/models.json).

<details>
<summary>Every model and precision: word error rate, speed, energy, Peak RAM</summary>

<!-- BENCHMARK_TABLE_START -->

Measured 1–3 October 2026 on Apple M5 Max, macOS 26.6. English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately; speed, energy and peak RAM: v2-quick (22.5 min). Languages are supported benchmark languages, out of 9.

**Standard** is plain MLX; **Optimized** adds custom kernels. Exact and Fast can share a recipe but retain separate measurement status. Standard and Exact for Whisper are not measured yet: their earlier Float32-baseline figures were withdrawn. Fast remains measured. Gates and presence for Whisper were judged against the withdrawn Float32 Standard, not shipped FP16 Standard.

| Model | Mode | Precision | Path | English WER % | Format % | Languages | Speed | J / min | Memory | Suite |
|---|---|---|---|---|---|---|---|---|---|---|
| Parakeet v3 Ultra | Dictation | 16 | Standard | 15.46 | 5.80 | 5/9 | 261.4× | 6.33 | 1,796 MB | v2 |
| Parakeet v3 Ultra | Dictation | 16 | Optimized · Exact | 15.49 | 5.74 | 5/9 | 474.5× | 4.71 | 1,808 MB | v2 |
| Parakeet v3 Ultra | Dictation | 16 | Optimized · Fast | 15.51 | 5.79 | 5/9 | 507.1× | 4.58 | 1,792 MB | v2 |
| Parakeet v3 Ultra | Dictation | 8 | Standard | 15.46 | 5.76 | 5/9 | 244.8× | 8.99 | 1,280 MB | v2 |
| Parakeet v3 Ultra | Dictation | 8 | Optimized · Exact | 15.46 | 5.77 | 5/9 | 369.0× | 8.62 | 1,888 MB | v2 |
| Parakeet v3 Ultra | Dictation | 8 | Optimized · Fast | 15.46 | 5.81 | 5/9 | 515.0× | 5.35 | 1,352 MB | v2 |
| Parakeet v3 Ultra | Dictation | 4 | Standard | 15.62 | 5.81 | 5/9 | 246.7× | 8.75 | 1,024 MB | v2 |
| Parakeet v3 Ultra | Dictation | 4 | Optimized · Exact | 15.65 | 5.84 | 5/9 | 370.6× | 8.41 | 1,640 MB | v2 |
| Parakeet v3 Ultra | Dictation | 4 | Optimized · Fast | 15.58 | 5.80 | 5/9 | 522.5× | 5.13 | 1,094 MB | v2 |
| Parakeet v3 | Dictation | 16 | Standard | 16.37 | 7.84 | 5/9 | 257.7× | 6.35 | 1,794 MB | v2 |
| Parakeet v3 | Dictation | 16 | Optimized · Exact | 16.42 | 7.92 | 5/9 | 463.9× | 4.81 | 1,777 MB | v2 |
| Parakeet v3 | Dictation | 16 | Optimized · Fast | 16.42 | 7.92 | 5/9 | 494.3× | 4.70 | 1,765 MB | v2 |
| Parakeet v3 | Dictation | 8 | Standard | 16.40 | 7.92 | 5/9 | 241.2× | 9.05 | 1,279 MB | v2 |
| Parakeet v3 | Dictation | 8 | Optimized · Exact | 16.35 | 7.81 | 5/9 | 363.3× | 8.68 | 1,883 MB | v2 |
| Parakeet v3 | Dictation | 8 | Optimized · Fast | 16.30 | 7.85 | 5/9 | 504.4× | 5.41 | 1,342 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 16 | Standard | 15.00 | 6.67 | 9/9 | 26.6× | 81.03 | 4,624 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 16 | Optimized · Exact | 15.00 | 6.67 | 9/9 | 29.6× | 72.73 | 5,118 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 16 | Optimized · Fast | 15.00 | 6.67 | 9/9 | 29.6× | 72.73 | 5,118 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 16 | Standard | 15.89 | 7.16 | 9/9 | 51.7× | 36.82 | 2,142 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 16 | Optimized · Exact | 15.89 | 7.16 | 9/9 | 64.4× | 34.07 | 2,406 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 16 | Optimized · Fast | 15.89 | 7.16 | 9/9 | 64.4× | 34.07 | 2,406 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 8 | Standard | 16.04 | 7.17 | 9/9 | 60.7× | 33.58 | 1,639 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 8 | Optimized · Exact | 16.04 | 7.17 | 9/9 | 82.0× | 30.05 | 1,920 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 8 | Optimized · Fast | 16.04 | 7.17 | 9/9 | 82.0× | 30.05 | 1,920 MB | v2 |
| Whisper large-v3 | Dictation | 16 | Standard | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 | Dictation | 16 | Optimized · Exact | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 | Dictation | 16 | Optimized · Fast | 17.06 | 8.17 | 9/9 | 34.8× | 83.50 | 3,915 MB | v2 |
| Whisper large-v3 | Dictation | 8 | Standard | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 | Dictation | 8 | Optimized · Exact | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 | Dictation | 8 | Optimized · Fast | 17.27 | 8.18 | 9/9 | 42.9× | 75.22 | 3,104 MB | v2 |
| Whisper large-v3 turbo | Dictation | 16 | Standard | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 turbo | Dictation | 16 | Optimized · Exact | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 turbo | Dictation | 16 | Optimized · Fast | 16.57 | 7.43 | 9/9 | 113.7× | 37.18 | 2,522 MB | v2 |
| Whisper large-v3 turbo | Dictation | 8 | Standard | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 turbo | Dictation | 8 | Optimized · Exact | — | — | — | — | — | — | Not measured yet |
| Whisper large-v3 turbo | Dictation | 8 | Optimized · Fast | 16.52 | 7.46 | 9/9 | 128.9× | 35.56 | 2,574 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 16 | Standard | 23.50 | 10.89 | 9/9 | 7.3× | 188.25 | 2,253 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 16 | Optimized · Exact | 23.39 | 10.57 | 9/9 | 19.3× | 80.33 | 2,725 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 16 | Optimized · Fast | 23.35 | 10.58 | 9/9 | 34.9× | 50.03 | 1,655 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 8 | Standard | 23.42 | 10.54 | 9/9 | 15.1× | 112.00 | 1,191 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 8 | Optimized · Exact | 23.42 | 10.54 | 9/9 | 29.8× | 58.71 | 1,251 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 8 | Optimized · Fast | 23.44 | 10.55 | 9/9 | 38.4× | 43.07 | 1,114 MB | v2 |
| ElevenLabs Scribe v2 (cloud API) | Dictation | — | — | ~13.4 (estimated, 11.8–13.9) | — | — | — | — | — | estimated |
| Microsoft Azure Speech (cloud API) | Dictation | — | — | ~12.9 (estimated, 11.3–13.3) | — | — | — | — | — | estimated |

Not offered: Parakeet v3 4 (3 clips empty or cut short where 16 had the words); Qwen3 ASR 1.7B 8 (1 clip empty or cut short where 16 had the words; Turkish +42.64 pt vs 16 (presence limit +10.0)); Qwen3 ASR 1.7B 4 (1 clip empty or cut short where 16 had the words); Qwen3 ASR 0.6B 4 (2 clips empty or cut short where 16 had the words); Whisper large-v3 4 (2 clips empty or cut short where 16 had the words); Whisper large-v3 turbo 4 (1 clip empty or cut short where 16 had the words); Nemotron 3.5 Streaming 4 (22 clips empty or cut short where 16 had the words; English WER +9.44 pt vs 16 (presence limit +5.0); multilingual mean +8.85 pt vs 16 (presence limit +5.0); Swedish +13.55 pt vs 16 (presence limit +10.0); Polish +13.09 pt vs 16 (presence limit +10.0); Turkish +12.29 pt vs 16 (presence limit +10.0); Japanese +10.46 pt vs 16 (presence limit +10.0); Chinese +10.23 pt vs 16 (presence limit +10.0)).

Cloud rows are estimates, not measurements; no audio was sent to them. Sources, ranges and arithmetic are in `references` in [`Resources/benchmarks.json`](Resources/benchmarks.json).

Build provenance (3 October 2026): measured build `55cb080`, built from `77be9f2`, worker SHA-256 `8a215e827e5972ef9afb4db7cf57ea8f068006f40ef1510ccd66e6977546b99d`, tag `full-8a215e827e59`. Shipped worker source `08203e24ebdf83004ca4d81daa03f678880898c2`; worker SHA-256: pending final candidate build. The [`Resources/benchmarks.json`](Resources/benchmarks.json) `builds` block records measured and shipped identities and the scoped bridge. Kept levers are on by default: Exact runs exact-only components, Fast runs all kept components, Standard runs none. Whisper Fast passed the recorded token-identity check (six cells, each 122/122 public clips).

<!-- BENCHMARK_TABLE_END -->

- **Precision** is bits per weight: 16 is the checkpoint as published, 8 and 4 are affine-quantized on your Mac from it. **Standard** and **Optimized** are the two ways to run a precision; **Exact** and **Fast** are Optimized's two recipes.
- **WER** is word error rate: the percentage of words wrong (substituted, missed or added) out of the words spoken, ignoring case and punctuation. It is the industry-standard metric, as on the Hugging Face Open ASR Leaderboard; our v2 set is hard (meetings, far-field microphones, accents, earnings calls), so rates run higher than on public leaderboards. **Format** is our own measure, with no industry standard: character error rate with case and punctuation kept, i.e. how much editing the finished text needs. Lower is better for both. Multilingual word error rates, per language, are in the WER tooltip.
- **Speed** is the real-time factor (RTFx): audio seconds per processing second, after the model is loaded; 100× means a minute of audio in 0.6 s. **J / min** is the energy the whole chip (CPU, GPU, Neural Engine and memory) used per minute of audio, idle power subtracted. **Peak RAM** is the peak footprint of the model worker, including loading.
- **Which tiers are offered.** A tier is offered unless it breaks against 16: a clip it leaves empty or cuts short, a request error, English or average word error rate 5 points worse, or one language 10 points worse. A tier that is merely worse is offered with its loss in the figures and the tooltip; Vella's quality gate (English word error rate within 0.1 points of 16, up to 0.2 points for a model whose measured run-to-run noise is larger, the other languages within a similar limit, no dropped or cut-off segments) says whether a tier loses nothing measurable. No tier is recommended: you choose.
- Figures were measured on an Apple M5 Max. On other Macs, speed, energy and memory differ; accuracy does not. The table says so on other chips.

Every figure is in [`Resources/benchmarks.json`](Resources/benchmarks.json); a sortable table is at https://tobynoskillson.github.io/Vella/.

</details>

## Install

```sh
curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash
```

Or from a checkout: `git clone https://github.com/TobyNoSkillSon/Vella && cd Vella && scripts/install.sh`. Either way the installer downloads the prebuilt app for this version with curl, checks its SHA-256 and code signature, clears quarantine, installs it in `~/Applications`, starts it and ends with `ready: …`. Coding agents can follow [AGENTS.md](AGENTS.md).

**Optional DMG.** An optional disk image is planned to accompany the 2.0.0 release; the ZIP remains the primary asset. Once available, open the image and drag Vella to Applications. The app is self-signed and not notarized: after macOS blocks its first launch, use **System Settings → Privacy & Security → Open Anyway**, then confirm. The command-line installer above needs no Gatekeeper step.

Open Vella from the menu bar, approve Microphone and Accessibility access, and press **Control + Command + N**. The first dictation without a model keeps the recording and offers **Get <model> (<size>)**; after the download it transcribes the waiting recording.

<details>
<summary>Updating, verification and uninstalling</summary>

**Updating.** `git pull && scripts/install.sh`. Models, recordings and settings are kept. The installer refuses while Vella is recording, transcribing or loading a model ("try again in a moment"); otherwise it quits Vella, swaps the app in place and restarts it. The previous app is kept until the new one reports ready, and restored if the swap fails. A certificate-signed installation is only replaced by an app with the same signing identity, so macOS privacy permissions carry over.

**Verification.** `scripts/install-release.sh <version> --dry-run` downloads and verifies a release without installing it. The SHA-256 detects a corrupted download; it comes from the same release, so it is not a signature. Download releases with the installer, not a browser: a browser adds the quarantine flag, and Gatekeeper then blocks the app.

**Uninstalling.** Quit Vella and move `~/Applications/Vella.app` to the Trash. Models, settings and recordings stay in `~/Library/Application Support/Vella`; delete that folder too if you want them gone.

</details>

<details>
<summary>Building from source</summary>

```sh
VELLA_BUILD=source scripts/install.sh    # build this checkout and install it
scripts/build.sh                         # build dist/Vella.app only
scripts/release-check.sh                 # what CI and the release workflow check, run locally
```

A source build needs the Command Line Tools Swift (`xcode-select --install`), full Xcode and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`); the installer checks each and prints the command that fixes a missing one. Swift compiles with the Command Line Tools and the MLX shaders with Xcode's Metal compiler. The app is a Swift menu-bar process (`Sources/Vella`) that supervises the recognition helpers (`Worker/`), one process per loaded model; the app itself downloads the models. `xcrun swift test` runs the unit tests. [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

</details>

## Using it

| Mode | What happens |
|---|---|
| **Dictation** | Speak, click the field you want the text in, then finish. Vella transcribes and pastes there. If focus changed before insertion, the text goes to the clipboard instead. |
| **Streaming** | Text appears as it is recognized, wherever keyboard focus is. Pause speaking while you move between fields. |

**The recording is kept.** Audio is written to disk as you speak; if transcription fails, or no model is installed yet, the recording waits and can be transcribed or retried later. Vella inserts text and never presses Enter.

**Shortcuts** (below **Microphone**) sets the key chord, a single modifier key or a mouse button, and **Toggle**, **Hold to Talk** or **Tap or Hold**. **Copy Last Transcript** recovers the most recent text; **Open Vella Files** shows saved recordings and transcripts.

**Audio files** go through the same models: `vella transcribe talk.m4a` (add `--srt` for subtitles). Your dictation always goes first.

**Something wrong, or slow on your Mac?** `vella diagnose` in Terminal reports your chip, versions, each loaded model's engine and fallbacks, and a timed run of five built-in clips compared with the reference Mac, and links to a prefilled GitHub issue. It includes nothing you dictated. See [Reporting a problem](docs/USAGE.md#reporting-a-problem).

<details>
<summary>The menu, the Models table, Keep Hot and Memory</summary>

Everything lives in the menu: the status line, then **Models… · Keep Hot · Memory**, then **Start Dictation** with **Mode · Microphone · Shortcuts**, your last transcript and saved recordings, then the agent skill, diagnostics, files, the worker and **Launch at Login**.

<p align="center">
  <img src="docs/images/menu-current.png" alt="Vella's menu: status, Models, Keep Hot, Memory, Start Dictation, Mode, Microphone, Shortcuts, Copy Last Transcript, Open Saved Recordings, Copy Skill for Your Agent, Open Vella Files, Start Worker, Launch at Login, Support and Quit" width="340">
</p>

**Models…** opens one table with Dictation and Streaming sections, one line per model; a thick line divides the two. Hover a model's name for what it is, its licence and its languages. **Precision** has two rows of three equal cells named by the format that runs (`bf16`, or `fp16` for Whisper, as released; `int8` and `int4` compressed on your Mac): **Optimized** (a bolt), Vella's kernels for your chip, above **Standard** (the MLX logo), plain MLX; every row shows all six cells, and a cell the model cannot run is greyed in place with the reason in its tooltip, so the grid never shifts. Every other cell is clickable and shows its own figures. Beside both rows a switch as tall as the pair chooses up **Fast** or down **Exact** for the Optimized row; click anywhere on it to flip it. It is greyed and pinned up where Fast measures the same as Exact. Exact offers only the precisions whose kernels give output identical to Standard, so flipping to Exact can move the precision to 16, and the line under the model's name says so. The small line under each figure is its difference from Standard bf16 when a baseline is measured. Whisper has no Standard baseline or multiplier; its measured Fast figures remain visible and withdrawn Standard/Exact cells show `—`. Rows keep their place when you switch: each column sorts by the model's best value across its precisions. A loaded model shows what it is loaded with; clicking another cell or flipping the switch previews it and, on a loaded model, shows a green **Reload**, which loads it; closing the menu discards the preview. While a model is recording, transcribing, streaming or loading, its segments and switch are locked; a change applies at the next load. What was last loaded is what dictation uses; a model never loaded starts on Optimized 16 · Fast. The last column is the row's button: **Get** downloads and loads (for a precision made on your Mac, it downloads the weights it is made from), **Load** keeps a model ready, **Unload** frees its memory; under the pointer a trash icon beside it deletes the weights. Every download first asks in a popup that names the model, precision, source and exact size; nothing downloads without **Download**.

**Engine.** Under a loaded model's name, **Optimized Fast · <your chip>** or **Optimized Exact · <your chip>** means Vella's kernels passed a self-test against the stock path on this Mac when the model loaded. **Standard** means the stock MLX path: the same model, slower. If the optimized path fails during a transcription, Vella redoes that transcription on the stock path and keeps the model there until it is reloaded.

**Keep Hot** sets how long an idle model stays loaded, timed per model from its last use:

| | Loaded how | Idle window | Next launch |
|---|---|---|---|
| **Manually loaded** | **Load** or **Reload** in the table | Always (default), 5, 15, 30 or 60 min | Loaded again |
| **Loaded on demand** | A dictation needed a model that was not loaded | 15 min (default), 5, 30, 60 min or Always | Not loaded |

**Memory → Fit in free memory**, the default, checks before each load that the model fits in memory macOS can hand out without swapping. If it does not, Vella unloads idle models to make room (on-demand ones first, least recently used first) or refuses the load and says how much it needs, how much is free and what to do. The check is best effort at load time, not a guarantee. **Allow swap (slower)** skips it.

The [user guide](docs/USAGE.md) covers every menu item, recovery and troubleshooting.

</details>

## For your agent

Install: follow [AGENTS.md](AGENTS.md), then `vella skill --install <skills directory>` writes `transcribe/SKILL.md`. **Copy Skill for Your Agent** in the menu copies the same text.

```sh
vella status                      # Vella 2.0.0 running (pid 29335), parakeet-v3-ultra 16 loaded · dictation model Parakeet v3 Ultra (16, Optimized Fast) · API http://127.0.0.1:63080/v1
vella transcribe talk.m4a         # the transcript as plain text
vella transcribe talk.m4a --srt   # SRT subtitles; also --vtt, --json, --verbose-json
vella models --json                # all catalog rows, cells, reasons, source and download size
vella select parakeet-v3-ultra --precision bf16 --path Optimized --mode Fast
vella get parakeet-v3-ultra --yes   # only after consent; downloads then loads
vella unload parakeet-v3-ultra      # free memory, keep downloaded weights
vella url                         # http://127.0.0.1:63080/v1
```

| API | |
|---|---|
| Compatible with | OpenAI audio transcriptions: `POST /v1/audio/transcriptions`, `GET /v1/models` |
| Base URL | `vella url` (127.0.0.1 only; the port changes when Vella restarts) |
| Key | Any; the SDKs require one |
| `model` | `whisper-1` = the user's dictation model, or an id from `/v1/models`; transcription never downloads a model |
| Formats | `text`, `json`, `verbose_json` (timed segments), `srt`, `vtt` |
| Input | wav, mp3, m4a, flac, caf, aiff; up to 3 hours per file |
| Not supported | Translation, speaker labels, word-level timestamps |

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:63080/v1", api_key="local")   # base_url from `vella url`
text = client.audio.transcriptions.create(model="whisper-1", file=open("talk.m4a", "rb"), response_format="text")
```

## Privacy

Audio and transcripts never leave your Mac. The recognition helpers run in a sandbox that denies all network access. The app's local API listens on 127.0.0.1 only and refuses browser requests. The only network traffic is model downloads from Hugging Face when you choose **Get**, and a once-a-day check for a newer release after a transcription (an ordinary GitHub request, no speech data). There is no telemetry. Apps you dictate into, clipboard managers and Universal Clipboard see the text you insert or copy.

[Verdict](https://github.com/TobyNoSkillSon/Verdict), [Vella](https://github.com/TobyNoSkillSon/Vella) and [Vireo](https://github.com/TobyNoSkillSon/Vireo) are free, open-source Mac apps that run AI models on your own Apple Silicon chip, for you and your coding agent: Verdict decides, Vella listens, Vireo speaks. [Sponsor them on GitHub](https://github.com/sponsors/TobyNoSkillSon).

## Licence

Vella 2.0 is [MIT-licensed](LICENSE). Published 0.x releases remain Apache-2.0; this does not change their licence retroactively. Keep the copyright and permission notice in [LICENSE](LICENSE), and the applicable [third-party notices](THIRD_PARTY_NOTICES.md), when you redistribute. Vella ships no model weights; each model's licence is in its tooltip in the app and in [`Resources/models.json`](Resources/models.json). The helpers include code adapted from mlx-audio-swift, mlx-audio and mlx-whisper (MIT) and link MLX and swift-transformers; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has each licence, and Vella.app carries it with LICENSE and NOTICE in `Contents/Resources`.
