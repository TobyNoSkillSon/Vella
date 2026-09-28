<p align="center">
  <img src="docs/images/icon.png" alt="" width="64">
</p>

<h1 align="center">Vella</h1>

<p align="center">Offline dictation and live transcription for Apple Silicon Macs.</p>

<p align="center">
  <a href="#install"><img src="docs/images/install.svg" alt="Install Vella" width="152" height="42"></a>
  &nbsp;
  <a href="https://github.com/sponsors/TobyNoSkillSon"><img src="docs/images/support.svg" alt="Support Vella on GitHub Sponsors" width="176" height="42"></a>
</p>

<p align="center">
  <a href="#models">Models</a> ·
  <a href="#the-app">The app</a> ·
  <a href="#install">Install</a> ·
  <a href="#using-it">Using it</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="docs/USAGE.md">User guide</a>
</p>

**Vella is a menu-bar app that turns speech into text on your Mac, with nothing leaving it.** Press a shortcut, speak, press it again: Vella transcribes with a local model and pastes the text where you were typing. Or switch to Streaming and watch words appear as you speak. Models run natively on Apple's MLX in sandboxed helper processes that have no network access.

<p align="center">
  <img src="docs/images/recording-current.png" alt="Recording: Vella's lavender waveform" width="320">
  <img src="docs/images/transcribing-current.png" alt="Transcribing: the waveform with progress and estimated time remaining" width="320">
</p>

- **Two ways to dictate.** Dictation inserts the transcript after you finish; Streaming types words as they are recognized.
- **Your recording is never lost.** Audio is written to disk as you speak. If transcription fails, or no model is installed yet, the recording waits and can be transcribed or retried later.
- **No automatic Send.** Vella inserts text; it never presses Enter.
- **Measured, not claimed.** Every accuracy, speed, energy and memory figure in the app comes from a benchmark run on real hardware, with its date. Anything not measured shows `—`.

## Models

Vella offers a small set of open speech-recognition models, each for a clear purpose: accuracy, size, languages, speed or another model family. A model can be offered even when another has a lower error rate, because it fits a Mac with less memory (Qwen3 ASR 0.6B), covers about 100 languages (Whisper large-v3) or is much faster (Whisper large-v3 turbo); the table shows every figure so you can choose. Each model runs at every precision from its native one down to 4 bits: 32, 16, 8 and 4 bits per weight, as far as its native precision allows. Precisions not published by the model's authors are made on your Mac from the higher one when first loaded; nothing extra is downloaded.

<!-- BENCHMARK_TABLE_START -->

Measured on Apple M5 Max, macOS 26.6, 2026-09-28. WER and Format on the 240-minute v2 benchmark (`v2`) or its 22.5-minute quick subset (`v2-quick`); Languages = benchmark languages supported, of 9.

| Model | Mode | Q | WER % | Format % | Languages | Speed | J / min | Memory | Suite |
|---|---|---|---|---|---|---|---|---|---|
| Parakeet v3 Ultra | Dictation | 16 (recommended) | 15.52 | 5.76 | 5/9 | 365× | 5.2 | 1,753 MB | v2 |
| Parakeet v3 Ultra | Dictation | 8 | 15.54 | 5.69 | 5/9 | 287× | 9.4 | 1,903 MB | v2 |
| Parakeet v3 Ultra | Dictation | 4 | 15.78 | 5.94 | 5/9 | 284× | 9.2 | 1,664 MB | v2 |
| Parakeet v3 | Dictation | 32 | 16.43 | 7.97 | 5/9 | 308× | 6.8 | 3,356 MB | v2 |
| Parakeet v3 | Dictation | 16 (recommended) | 16.43 | 7.98 | 5/9 | 368× | 4.7 | 1,785 MB | v2 |
| Parakeet v3 | Dictation | 8 | 16.55 | 8.05 | 5/9 | 279× | 9.4 | 1,804 MB | v2 |
| Parakeet v3 | Dictation | 4 | 17.84 | 9.24 | 5/9 | 278× | 9.5 | 1,537 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 16 | 15.03 | 6.88 | 9/9 | 28× | 75.5 | 4,492 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 8 (recommended) | 15.07 | 6.75 | 9/9 | 42× | 67.8 | 3,092 MB | v2 |
| Qwen3 ASR 1.7B | Dictation | 4 | 15.37 | 7.10 | 9/9 | 57× | 54.5 | 2,259 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 16 | 15.99 | 7.26 | 9/9 | 59× | 36.8 | 2,030 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 8 (recommended) | 16.05 | 7.30 | 9/9 | 77× | 31.5 | 1,547 MB | v2 |
| Qwen3 ASR 0.6B | Dictation | 4 | 17.62 | 8.48 | 9/9 | 90× | 26.4 | 1,273 MB | v2 |
| Whisper large-v3 | Dictation | FP16 (recommended) | 17.68 | 8.63 | 9/9 | 28× | 94.1 | 3,889 MB | v2 |
| Whisper large-v3 | Dictation | 8 | 17.78 | 8.60 | 9/9 | 32× | 110.8 | 2,656 MB | v2 |
| Whisper large-v3 | Dictation | 4 | 17.75 | 8.82 | 9/9 | 39× | 97.5 | 2,067 MB | v2 |
| Whisper large-v3 turbo | Dictation | FP16 (recommended) | 17.31 | 7.69 | 9/9 | 76× | 58.5 | 2,459 MB | v2 |
| Whisper large-v3 turbo | Dictation | 8 | 17.21 | 7.70 | 9/9 | 77× | 64.8 | 1,922 MB | v2 |
| Whisper large-v3 turbo | Dictation | 4 | 17.80 | 8.43 | 9/9 | 80× | 63.5 | 1,689 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 16 | 23.42 | 10.55 | 9/9 | 20× | 78.9 | 2,700 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 8 (recommended) | 23.47 | 10.58 | 9/9 | 29× | 47.0 | 1,160 MB | v2 |
| Nemotron 3.5 Streaming | Streaming | 4 | 32.97 | 16.19 | 9/9 | 28× | 40.2 | 895 MB | v2 |
| ElevenLabs Scribe v2 (cloud API) | Dictation | — | ~13.4 (estimated, 11.8–13.9) | — | — | — | — | — | estimated |
| Microsoft Azure Speech (cloud API) | Dictation | — | ~12.9 (estimated, 11.3–13.3) | — | — | — | — | — | estimated |

Cloud API rows are **estimates, not measurements**: we sent no audio to them. Each is the provider's WER on the Hugging Face Open ASR Leaderboard times the median ratio between our v2 WER and the leaderboard WER of the models we measured on both (Parakeet v3, Qwen3 ASR 1.7B, Nemotron 3.5 Streaming); the range uses the lowest and highest ratio. Leaderboard: https://huggingface.co/spaces/hf-audio/open_asr_leaderboard. Sources, anchors and arithmetic are in `references` in [`Resources/benchmarks.json`](Resources/benchmarks.json).

Measured but not offered in the app:

| Model | Mode | Q | WER % | Format % | Languages | Speed | J / min | Memory | Suite |
|---|---|---|---|---|---|---|---|---|---|
| Parakeet TDT-CTC 110M | Dictation | 32 (recommended) | 9.25 | 6.01 | 0/9 | 222× | 5.0 | 889 MB | v2-quick |
| SenseVoice Small | Dictation | 32 (recommended) | 11.01 | 7.77 | 3/9 | 420× | — | 1,548 MB | v2-quick |

<!-- BENCHMARK_TABLE_END -->

- **Q** is bits per weight: 32 is FP32, 16 is BF16, 8 and 4 are quantized. Whisper's native FP16 shows as FP16.
- **WER** is word error rate: the percentage of words wrong (substituted, missed or added) out of the words spoken, ignoring case and punctuation. It is the industry-standard metric, as on the Hugging Face Open ASR Leaderboard; our v2 set is hard (meetings, far-field microphones, accents, earnings calls), so rates run higher than on public leaderboards. **Format** is our own measure, with no industry standard: character error rate with case and punctuation kept, i.e. how much editing the finished text needs. Lower is better for both. Multilingual word error rates, per language, are in the WER tooltip.
- **Speed** is the real-time factor (RTFx): audio seconds per processing second, after the model is loaded; 100× means a minute of audio in 0.6 s. **J / min** is the energy the whole chip (CPU, GPU, Neural Engine and memory) used per minute of audio, idle power subtracted. **Memory** is the loaded model's footprint.
- **Recommended precision.** A model shows its recommended precision until it has been loaded at another: among its measured precisions whose WER is within 0.5 points of its native precision, the one with the lowest energy per minute of audio (ties: faster, then more bits).
- Figures were measured on an Apple M5 Max. On other Macs, speed, energy and memory differ; accuracy does not. The table says so on other chips.

Every figure is in [`Resources/benchmarks.json`](Resources/benchmarks.json); a sortable table is at https://tobynoskillson.github.io/Vella/.

## The app

Everything lives in the menu: the status line, **Mode · Microphone · Shortcuts**, then **Models… · Keep Hot · Memory**, then your last transcript, files and **Launch at Login**.

<p align="center">
  <img src="docs/images/menu.png" alt="Vella's menu: status, Start Dictation, Mode, Microphone, Shortcuts, Models, Keep Hot, Memory, copy and file items, Launch at Login, Support and Quit" width="340">
</p>

**A fresh install downloads and loads nothing.** The first time you dictate without a model, Vella keeps the recording and shows one **Get <model> (<size>)** item for the recommended model; after you confirm the download, it transcribes the waiting recording when the download finishes. **Models…** does the same ahead of time.

**Models…** opens one table with Dictation and Streaming sections. Pick a precision in a row's **Q** control (32, 16, 8, 4); the recommended one is green, and each segment's tooltip names the exact format and whether it is published or made on your Mac. Rows keep their place when you switch precision: each column sorts by the model's best value across its precisions. A loaded model shows the precision it is loaded at; clicking another segment previews it (its figures against the recommended one) and, on a loaded model, turns the button into a green **Reload**, which loads it; closing the menu discards the preview. The precision last loaded is the one dictation uses. **Get** downloads and loads (for a precision made on your Mac, it downloads the weights it is made from), **Load** keeps a model ready, **Unload** frees its memory, and the trash icon deletes its weights. Every download first asks in a popup that names the model, precision, source and exact size; nothing downloads without **Download**.

<p align="center">
  <img src="docs/images/models.png" alt="The Models table: Parakeet v3 loaded at 4 bits and Optimized on an M5 Max, with its figures against the recommended 16, Nemotron loaded for Streaming, and two estimated cloud API rows" width="920">
</p>

**Engine.** Under a loaded model's name, **Optimized · <your chip>** means Vella's optimized kernels passed a self-test against the stock path on this Mac when the model loaded. **MLX** means the stock MLX path: the same model, slower. If the optimized path fails during a transcription, Vella redoes that transcription on the stock path and keeps the model there until it is reloaded.

**Keep Hot** sets how long an idle model stays loaded, timed per model from its last use:

| | Loaded how | Idle window | Next launch |
|---|---|---|---|
| **Manually loaded** | **Load** or **Reload** in the table | Always (default), 5, 15, 30 or 60 min | Loaded again |
| **Loaded on demand** | A dictation needed a model that was not loaded | 15 min (default), 5, 30, 60 min or Always | Not loaded |

**Memory → Fit in free memory**, the default, checks before each load that the model fits in memory macOS can hand out without swapping. If it does not, Vella unloads idle models to make room (on-demand ones first, least recently used first) or refuses the load and says how much it needs, how much is free and what to do. The check is best effort at load time, not a guarantee. **Allow swap (slower)** skips it.

## Install

Apple Silicon, macOS 14 or newer. The prebuilt app needs no Xcode, Python or developer account.

```sh
git clone https://github.com/TobyNoSkillSon/Vella && cd Vella
scripts/install.sh
```

`scripts/install.sh` downloads the prebuilt app for this version with curl, checks its SHA-256 and code signature, installs it in `~/Applications`, starts it, and waits until it is ready. It prints a few short lines and ends with `ready: …`. Coding agents can follow [AGENTS.md](AGENTS.md).

Without git, the same installer is one command:

```sh
curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash
```

Open Vella from the menu bar, approve Microphone and Accessibility access, and press **Control + Command + N** to start dictating. Press it again to finish.

<details>
<summary>Updating, verification and uninstalling</summary>

**Updating.** `git pull && scripts/install.sh`. Models, recordings and settings are kept. The installer refuses while Vella is recording, transcribing or loading a model ("try again in a moment"); otherwise it quits Vella, swaps the app in place and restarts it. The previous app is kept until the new one reports ready, and restored if the swap fails. A certificate-signed installation is only replaced by an app with the same signing identity, so macOS privacy permissions carry over.

**Verification.** `scripts/install-release.sh <version> --dry-run` downloads and verifies a release without installing it. The SHA-256 detects a corrupted download; it comes from the same release, so it is not a signature. Download releases with the installer, not a browser: a browser adds the quarantine flag, and Gatekeeper then blocks the app.

**Uninstalling.** Quit Vella and move `~/Applications/Vella.app` to the Trash. Models, settings and recordings stay in `~/Library/Application Support/Vella`; delete that folder too if you want them gone.

</details>

## Using it

| Mode | What happens |
|---|---|
| **Dictation** | Speak, click the field you want the text in, then finish. Vella transcribes and pastes there. If focus changed before insertion, the text goes to the clipboard instead. |
| **Streaming** | Text appears as it is recognized, wherever keyboard focus is. Pause speaking while you move between fields. |

**Shortcuts** (below **Microphone**) sets the key chord, a single modifier key or a mouse button, and **Toggle**, **Hold to Talk** or **Tap or Hold**. **Copy Last Transcript** recovers the most recent text; **Open Vella Files** shows saved recordings and transcripts. The [user guide](docs/USAGE.md) covers every menu item, recovery and troubleshooting.

**Audio files** go through the same models: `vella transcribe talk.m4a` (add `--srt` for subtitles), or any OpenAI SDK pointed at the local API (`base_url` from `vella url`, `/v1/audio/transcriptions`). Your dictation always goes first. **Copy Skill for Your Agent** copies the instructions for a coding agent. Details: [user guide](docs/USAGE.md#transcribe-files-command-line-and-api).

**Something wrong, or slow on your Mac?** **Copy Diagnostics** in the menu (or `vella diagnose`) reports your chip, versions, each loaded model's engine and fallbacks, and a timed run of five built-in clips compared with the reference Mac, and links to a prefilled GitHub issue. It includes nothing you dictated. See [Reporting a problem](docs/USAGE.md#reporting-a-problem).

## Privacy

Audio and transcripts never leave your Mac. The recognition helpers run in a sandbox that denies all network access. The app's local API listens on 127.0.0.1 only and refuses browser requests. The only network traffic is model downloads from Hugging Face when you choose **Get**, and a once-a-day check for a newer release after a transcription (an ordinary GitHub request, no speech data). There is no telemetry. Apps you dictate into, clipboard managers and Universal Clipboard see the text you insert or copy.

## Building from source

```sh
VELLA_BUILD=source scripts/install.sh    # build this checkout and install it
scripts/build.sh                         # build dist/Vella.app only
```

A source build needs the Command Line Tools Swift (`xcode-select --install`), full Xcode and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`); the installer checks each and prints the command that fixes a missing one. Swift compiles with the Command Line Tools and the MLX shaders with Xcode's Metal compiler. The app is a Swift menu-bar process (`Sources/Vella`) that supervises the recognition helpers (`Worker/`), one process per loaded model, and `VellaModelTool` for downloads. `xcrun swift test` runs the unit tests.

## License

[Apache-2.0](LICENSE). Keep the [NOTICE](NOTICE) when you redistribute. Vella ships no model weights; each model's licence is shown in its table tooltip and in [`Resources/models.json`](Resources/models.json). The helpers include code adapted from mlx-audio-swift, mlx-audio and mlx-whisper (MIT) and link MLX and swift-transformers; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has each licence, and Vella.app carries it with LICENSE and NOTICE in `Contents/Resources`.
