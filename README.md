# Vella

Local dictation for Apple Silicon Macs. Press **⌃⌘N**, speak, then press it again. Vella transcribes on your Mac and pastes into the field you started in. It never presses Enter or Send.

A small native menu-bar app, with a lavender waveform while recording. No Dock icon, account, subscription or external inference server.

**Source beta · macOS 14+ · Apple Silicon**

## Install

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.6.0/scripts/install.sh | bash
```

The installer builds Vella locally and installs it in `~/Applications/Vella.app`. It verifies the release source archive against its published SHA-256 and installs the pinned MLX dependencies automatically.

You need:

- **Apple's free Command Line Tools.** If missing, run `xcode-select --install`, finish the installation, then rerun the command.
- **Existing Apple Silicon Python 3.12–3.14.** If missing, install it from [python.org](https://www.python.org/downloads/macos/), then rerun. You can select an interpreter with `PYTHON=/path/to/python3` on the `bash` side of the pipe.

No Apple Developer enrollment, paid membership, Homebrew registration or `sudo`. The installer does not download a private Python interpreter or disable macOS security settings. It builds an ad-hoc-signed app rather than downloading a notarized binary. **Updates may require approving macOS privacy permissions again.**

As with any curl-to-shell installer, use a trusted URL. The archive checksum checks the downloaded source; it does not independently authenticate the bootstrap script. You can [read the installer](scripts/install.sh) before running it.

### First use

1. Open Vella from `~/Applications`.
2. Open **Models**, click **Install** next to **Parakeet Q4**, then **Use**. Downloads are explicit, checksum-verified and resumable.
3. Approve **Accessibility** and **Microphone** when requested. Screen Recording and Input Monitoring are not required.
4. Put the cursor in a text field. Press **Control + Command + N**, speak, then press it again to finish.

Choose your preferred microphone from the menu. Vella falls back to the MacBook microphone when available; it does not change the system default or silently choose an iPhone. Stop recording before unplugging a microphone.

## What happens to your speech

Transcription runs locally in Vella's own offline worker. There is no listening port or dependency on another app's model server. Downloading the app, packages and model weights needs an internet connection; ordinary transcription does not.

Vella pastes only after you explicitly finish, the complete transcript is saved, and the original application, window and focused field still match. If focus changes, it leaves the transcript on the clipboard for you to paste. Recovery and Retry are always clipboard-only. Vella never sends Return/Enter or tries to switch focus back.

**Recordings and transcripts are kept until you delete them.** Use **Open Saved Recordings** to open their folder in Finder:

```text
~/Library/Application Support/Vella/Recordings/
```

Successful paste, cancellation, a new recording and normal quit do not erase that history. Original audio and completed transcription checkpoints remain available after a failed request. Incomplete results are marked explicitly and are never pasted automatically.

There is no recording-duration cutoff. Audio is written to disk in small segments, using roughly **230 MB/hour**, plus overlap and metadata. Low disk space, disconnected hardware, closing the lid or forced sleep can still interrupt capture; this is not a promise of unlimited storage or lossless recovery from every failure.

The worker discards third-party diagnostic output rather than saving recognized speech in a backend log. Clipboard managers and Universal Clipboard may still see text copied or pasted by Vella. After an automatic paste, Vella restores only a small, plain-text previous clipboard item, and only if nothing else changed the clipboard.

## Memory and responsiveness

Only one model is resident. Vella clears temporary MLX allocations after each request, releases the old worker before switching models or calibrating, and unloads its worker after **60 seconds idle**. Cancellation and shutdown terminate its owned worker, not unrelated services.

With **Parakeet Q4 on an M5 Max / 128 GiB Mac**, an accelerated hour-long corpus replay measured:

| Measurement | Result |
|---|---:|
| Worker physical footprint after requests | 0.98–1.04 GB |
| Worker lifetime peak physical footprint | 1.42 GB |
| Active MLX allocation after requests | 0.68 GB, steady |
| Allocator cache after requests | 0 bytes |
| Audio / processing time | 3,619 seconds / 30 seconds |
| Lexical word errors | 249 / 8,955 · **2.78%** |

These are worker-process measurements, not total system RAM or a minimum hardware requirement. The Swift app uses additional memory. Larger models need more RAM, and other Macs can behave differently. Worker exit after the idle timeout was checked with real inference. The hour replay used recorded benchmark material, not an hour-long physical microphone endurance test.

Fast jobs show only the waveform. Percentage and remaining time appear only when the initial processing estimate exceeds five seconds. Estimates are not measured progress and can be wrong during loading or contention.

## Models and benchmarks

Start with **Parakeet Q4** for English dictation. The menu also recommends Qwen Q4, Whisper Q8, Granite Q4 and SenseVoice FP32. Granite and SenseVoice produced little or no punctuation in these tests. Recommendations are practical defaults, not universal rankings.

<!-- BENCHMARK_RESULTS_START -->

Apple M5 Max · 128 GiB unified memory · MLX Audio 0.5.1 · MLX 0.32.2. **★ marks the app recommendation for that family.**

| Model / quantization | Word errors ↓ | Text errors ↓ | Punctuation F1 ↑ | Warm speed ↑ | Warm MLX RAM |
|---|---:|---:|---:|---:|---:|
| Parakeet v3 4-bit ★ | 1.54% | 1.77% | 75.4% | 233.7× | 1.34 GB |
| Parakeet v3 8-bit | 1.60% | 1.85% | 75.3% | 237.4× | 1.61 GB |
| Qwen3 1.7B BF16 | 1.41% | 2.08% | 75.2% | 30.5× | 5.50 GB |
| Qwen3 1.7B 4-bit ★ | 1.51% | 2.12% | 75.0% | 59.5× | 3.03 GB |
| Qwen3 1.7B 8-bit | 1.57% | 2.14% | 75.5% | 44.5× | 3.89 GB |
| Whisper large-v3 8-bit ★ | 2.60% | 4.50% | 46.6% | 21.0× | 2.52 GB |
| Granite 4.0 1B 4-bit ★ | 1.29% | 4.61% | 0.9% | 44.1× | 7.64 GB |
| Granite 4.0 1B 8-bit | 1.19% | 4.61% | 0.9% | 37.4× | 8.56 GB |
| Whisper large-v3 FP16 | 2.82% | 4.76% | 46.1% | 19.7× | 4.03 GB |
| SenseVoice FP32 ★ | 2.45% | 5.05% | 0.0% | 631.6× | 1.79 GB |
| SenseVoice 4-bit | 3.45% | 5.40% | 0.0% | 582.3× | 0.88 GB |
| Whisper large-v3 4-bit | 4.14% | 6.30% | 48.5% | 22.2× | 1.75 GB |

<!-- BENCHMARK_RESULTS_END -->

**Lower errors are better.** Word errors ignore case and punctuation. Text errors measure character edits against the written reference, including case and punctuation; valid editorial alternatives can still count as errors.

The suite contains **144 intact clips, 34 speakers and 20m 15s of clean English reading**, with [LibriSpeech-PC](https://www.openslr.org/145/) formatted references. Each clip has two measured inference passes. Accuracy uses the first transcript; speed uses median warm latency. Memory was measured separately over the same suite after warmup.

**Warm speed excludes loading, transport, capture and paste. Warm MLX RAM is allocator peak, not total process memory**, and must not be added to RSS. Punctuation F1 is conditional on aligned words and boundaries. Only three usable quotation clips remain, so quotation scores are exploratory. These results do not establish performance on noisy, spontaneous or multilingual dictation, or spoken paragraph commands.

[Raw results](Resources/ReferenceResults/) · [Memory measurements](Resources/MemoryResults/) · [Scoring policy](Resources/benchmark-policy.json) · [Benchmark corpus](Resources/Benchmarks/english-formatted-20m-v1/)

The [sortable explorer](docs/index.html) can be opened locally from a checkout. GitHub displays HTML source rather than running it; GitHub Pages is not configured.

### Managing models

The native Models table shows the five recommendations plus installed exceptions. Click a column heading to sort. Install downloads weights; Use selects them. Cancel keeps resumable download data. An offline calibration after installation helps estimate processing time without using your speech.

The trash button asks for confirmation and moves an inactive, Vella-owned model folder to macOS Trash. Active models and external/shared/linked folders are protected. Recordings, transcripts and reference scores are retained. Empty Trash to reclaim disk space. Recovering an older recording can require reinstalling its model.

The footer **“Want another model? Copy instructions for your agent.”** copies a pointer to the [integration guide](Resources/AGENT_GUIDE.md). It sends nothing automatically.

## Updates and uninstalling

Run the installer from the release you want to install. It prepares the app and dependencies before replacing the existing copy, refuses to update during dictation, and preserves model and microphone choices. Existing weights are not downloaded again for a runtime update.

Use `VELLA_APP_PATH=/existing/path/Vella.app` on the `bash` side of the pipe if your app is elsewhere. The installer refuses to replace a certificate-signed installation with an ad-hoc build; use that installation's existing signing workflow instead.

To uninstall, quit Vella and move its app to Trash. Its data remains in `~/Library/Application Support/Vella`. Delete that folder separately **only if you also want to remove your recordings, transcripts, models and runtime packages**. The reused Python interpreter is never removed.

## Build and test from source

```sh
git clone https://github.com/TobyNoSkillSon/Vella.git
cd Vella
./scripts/install.sh
```

For development without installing:

```sh
swift test
python3 -m unittest discover -s Tests -p '*_test.py'
swift build -c release
```

The Swift app has no third-party Swift package dependencies. Python versions are pinned in [runtime-requirements.txt](Resources/runtime-requirements.txt). Runtime preparation can be run separately with `scripts/setup-backend.sh --runtime-only`; `--migrate-runtime` selects it while retaining model/microphone choices and saving a rollback config. Weights live separately from versioned package environments.

An opt-in long replay checks completed transcripts, exact recovered audio hashes and a default 5% WER ceiling:

```sh
VELLA_LONG_SUITE="$PWD/Resources/Benchmarks/english-formatted-20m-v1" \
  swift test --filter LongRecordingTests.testHourOfCorpusThroughCaptureAndRealBackend
```

Configure the private runtime and install a model first. `VELLA_MAX_LONG_WER` explicitly changes the threshold when evaluating another model. Ordinary tests do not record your microphone. CI checks source builds; it does not publish releases or notarize binaries.

## Beta limits

Recognition still needs proofreading, especially around speaker changes, forced segment boundaries and repeated phrases. Tests cover capture conversion, persistence, bounded recovery, worker failure/cancellation, idle release and focus-safe paste. They are not fresh-Mac Gatekeeper/TCC certification or exhaustive microphone, language and noise testing.

Launch at login is not enabled. The app must remain running for the shortcut to work.

## License

Vella's original code is [Apache 2.0](LICENSE). See [NOTICE](NOTICE) and [third-party notices](THIRD_PARTY_NOTICES.md). Model and dependency licenses remain separate. Benchmark audio and the bundled calibration sample are CC BY 4.0, with attribution and hashes alongside the files.
