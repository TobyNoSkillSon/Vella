# Vella

Vella is a dictation app for Apple Silicon Macs. Press **⌃⌘N** to record, speak, then press it again to put the text where your cursor was. Transcription runs on your Mac using [MLX Audio](https://github.com/Blaizzy/mlx-audio).

It lives in the menu bar. A small waveform appears while you speak and disappears when you're done.

| Recording | Transcribing a longer recording |
|:---:|:---:|
| <img src="docs/images/recording.png" alt="Vella's lavender recording waveform over the desktop" width="320"> | <img src="docs/images/transcribing.png" alt="Vella processing a recording with an estimated percentage and time remaining" width="320"> |

## Install

**macOS 14+ · Apple Silicon · Python 3.12–3.14**

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.6.0/scripts/install.sh | bash
```

The installer builds the app locally, puts it in `~/Applications`, and sets up its Python packages. You'll need Apple's free Command Line Tools (`xcode-select --install`) and an existing Apple Silicon Python from [python.org](https://www.python.org/downloads/macos/) or your usual package manager. If either is missing, the installer tells you what to do.

No account or paid developer membership is needed. This is a **source beta**, not a notarized app download. macOS may ask you to approve permissions again after an update. [Read the installer](scripts/install.sh).

## Start dictating

1. Open Vella and choose **Models → Install** beside **Parakeet Q4**, then **Use**.
2. Allow Microphone and Accessibility access when prompted.
3. Click a text field and press **Control + Command + N**. Press it again when you're finished.

Vella pastes the finished transcript, but never presses Enter or Send. If you switch to another window or field while recording, it copies the text to your clipboard instead. Retry also copies rather than pasting.

You can choose a microphone from the menu. Vella falls back to the MacBook microphone when available and leaves your system input setting alone.

## Recordings stay on your Mac

There's no recording timer. Audio is saved as you speak, and transcription picks up from saved checkpoints if something fails. Storage works out to about **230 MB per hour**. Running out of space, disconnecting the microphone or closing the lid can still interrupt a recording.

**Audio and transcripts are kept until you delete them**, including after a successful paste. Choose **Open Saved Recordings** to find them in Finder. Incomplete transcripts are labelled and aren't pasted automatically.

Once the packages and a model are downloaded, transcription works offline. Clipboard managers and Universal Clipboard can still see text you copy or paste.

## Choosing a model

Start with **Parakeet Q4** for English. The Models menu lets you compare accuracy, speed and memory use, install another model, or remove one you no longer need. Downloads can be cancelled and resumed. Removing a model moves its files to Trash; it doesn't delete your recordings.

Only one model is loaded at a time. Vella releases it after a minute without transcription, rather than keeping every installed model in memory. Longer jobs show an estimated time remaining; short jobs just show the waveform.

<details>
<summary><strong>Model benchmarks</strong></summary>

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

These results come from 144 clean English reading clips: 34 speakers and 20m 15s of audio, with [LibriSpeech-PC](https://www.openslr.org/145/) written references. Each clip was transcribed twice; accuracy uses the first transcript and speed uses median warm latency. Memory was measured in a separate pass.

**Word errors** ignore case and punctuation. **Text errors** include them. Lower is better for both. Punctuation F1 measures agreement with the reference at aligned words and boundaries; valid editorial choices can still differ.

Warm speed excludes loading, capture and paste. Warm MLX RAM is peak allocator usage, **not total process memory** or a minimum Mac specification. These are clean-reading tests, not a guarantee for every accent, language or noisy room.

In a separate hour-long Parakeet Q4 replay, the worker used about **1 GB after requests**, peaked at **1.42 GB**, and finished in **30 seconds with 2.78% word errors** on the same M5 Max. That was recorded corpus playback, not an hour-long microphone endurance test; the Swift app uses additional memory.

[Raw results](Resources/ReferenceResults/) · [Memory measurements](Resources/MemoryResults/) · [Scoring policy](Resources/benchmark-policy.json) · [Corpus](Resources/Benchmarks/english-formatted-20m-v1/) · [Sortable explorer](docs/index.html) (open locally)

</details>

## Updates and removal

Use the installer from the release you want. It keeps your models, recordings and microphone choices. If Vella is installed somewhere else, set `VELLA_APP_PATH=/your/path/Vella.app` on the `bash` side of the install command. The installer won't replace a certificate-signed copy with an ad-hoc build.

To uninstall, quit Vella and move the app to Trash. Your data stays in:

```text
~/Library/Application Support/Vella/
```

Delete that folder separately only if you also want to remove the recordings, transcripts, models and runtime packages.

## Development

```sh
git clone https://github.com/TobyNoSkillSon/Vella.git
cd Vella
./scripts/install.sh
```

Run `swift test` and `python3 -m unittest discover -s Tests -p '*_test.py'` for the tests, or `swift build -c release` to build without installing. Python dependencies are [version-pinned](Resources/runtime-requirements.txt). See the [integration guide](Resources/AGENT_GUIDE.md) for adding models and running benchmarks.

Vella is still a beta. Proofread its output, especially around speaker changes and repeated phrases. It doesn't launch at login, so keep it running for the shortcut to work.

## License

[Apache 2.0](LICENSE). Model and dependency licenses are separate; the benchmark audio and calibration sample are CC BY 4.0. See [third-party notices](THIRD_PARTY_NOTICES.md).
