<img src="docs/images/icon.png" alt="Vella icon" width="96">

# Vella — Minimal offline transcription for macOS

Vella is a minimal, native menu-bar app for offline dictation and live speech-to-text on Apple Silicon Macs. It supports selectable local MLX models, a global keyboard shortcut, and saved recordings with transcription recovery.

## Install or update

For **Apple Silicon Macs running macOS 14 or newer**.

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.8.8/scripts/install.sh | bash
```

The installer builds Vella and puts it in `~/Applications`. It needs Apple's free Command Line Tools and Python 3.12–3.14; if either is missing, it'll tell you how to install it. No paid developer membership is needed.

Checksums detect archive corruption or mismatches; they do not independently authenticate the downloaded bootstrap script.

It checks the selected Apple tools before building, verifies the source archive, and preserves existing models, recordings and settings during updates. For an update, run the command from the newer release, after finishing any recording or transcription. Running the same pinned command again retries or reinstalls that version; it does not discover newer releases. It does not change your selected toolchain or disable macOS security checks.

Vella is a beta. macOS will ask for Microphone and Accessibility access, and you may need to approve permissions again after an update.

Press **⌃⌘N** to open or close the microphone. Dictation inserts the transcript when you finish; Streaming inserts text as you speak.

[**Interactive benchmarks ↗**](https://tobynoskillson.github.io/Vella/) · [Model integration guide](Resources/AGENT_GUIDE.md) · [License](LICENSE)

## A look inside

The waveform appears while you speak. Longer jobs also show an estimated time remaining.

| Recording | Transcribing |
|:---:|:---:|
| <img src="docs/images/recording-0.8.6.png" alt="Vella’s lavender waveform while recording" width="320"> | <img src="docs/images/transcribing-0.8.6.png" alt="Vella’s waveform and time estimate while transcribing" width="320"> |

<img src="docs/images/menu-0.8.6.png" alt="Vella’s current native menu with Mode, Microphone, Models, saved files and developer support" width="304">

Pick a microphone, start recording, or open your saved transcripts from the menu. Open **Models** to choose what handles the transcription.

<img src="docs/images/models-0.8.6.png" alt="Vella’s current native Models menu" width="580">

*Captured from the native v0.8.6 interface, with example waveform and progress states. The table shows reference benchmarks; results vary by Mac.*

## Get started

**Update notices:** After a completed transcription, Vella checks GitHub’s latest stable release only if it has not attempted a check that calendar day. The last attempt and a detected update are remembered across restarts; there is no startup request or polling timer. A newer version turns the menu-bar icon yellow and adds a yellow **Update available…** immediately above **Support the developer…**, opening its release page in your browser. Nothing is installed automatically, and this check needs no additional permissions. Offline or failed checks are silent and do not clear a known update. The indicator remains until you install that version or newer. GitHub receives a normal HTTPS request, never audio or transcripts.

A new installation automatically downloads and selects **Parakeet Q4** (about 637 MB). Existing installations retain their model choices.

1. Open Vella and approve Microphone and Accessibility access when requested.
2. Press **Control + Command + N** to record. Click your destination text field, then press the shortcut again to finish. This remains the default; **Shortcuts**, directly below **Microphone**, lets you change activation.
3. For live transcription, choose **Mode → Streaming**, then **Models** to install and select a supported Streaming model. You can also change the Dictation model there.

A small waveform appears while you speak. Vella pastes the finished text but never presses Enter or Send. If you change the selected window or field after Finish but before insertion, it leaves the text on your clipboard instead.

### Shortcuts

These options are in the current source checkout. The pinned v0.8.8 installer does not include them yet.

Choose a key combination, a left/right modifier key, or a middle/side mouse button. The primary and secondary mouse buttons remain ordinary clicks.

Selecting a mouse button shows a red confirmation prompt in that same menu row. Press and release the requested button once to save it; the confirming click does not start recording. A different button adds feedback such as “Button 5 detected” while Vella keeps waiting for the requested button. If no matching click arrives within 10 seconds, the row reports that the button was not detected and your previous shortcut is unchanged. Closing the menu cancels confirmation. Mouse remapping software may prevent a standard button event from reaching Vella; a timeout alone cannot identify the cause.

- **Toggle:** activate once to start and again to finish.
- **Hold to Talk:** hold to record, release to finish.
- **Tap or Hold:** a short tap toggles recording; holding for at least 300 ms finishes on release.

Modifier-only triggers are recognized when used alone, with a brief guard before hold activation so normal key combinations do not start recording. Fn availability depends on the keyboard and macOS settings. Permission or registration failures are shown rather than silently replacing a working shortcut. Shortcut changes are disabled during capture and processing; **Reset to Default** restores **⌃⌘N · Toggle**. Model and microphone choices are unchanged.

### Dictation and Streaming

Choose **Mode → Dictation / Streaming**. Dictation transcribes and inserts after you finish. **Streaming inserts text continuously wherever keyboard focus is**, using native incremental recognition. Both modes use your configured activation, **⌃⌘N** by default. Finish sends only the remaining suffix, never a duplicate full transcript.

Streaming follows window and field changes without stopping for clicks or manual typing. It deliberately does not bind words to a field or utterance: words still being processed when you switch will go to the new focus. Pause your speech or close the microphone while navigating as needed. Streaming sends native Unicode text without touching the clipboard or pressing Enter. Dictation uses the field focused when you finish, with a final safety check before pasting; terminal and custom-editor acceptance depends on the target application.

Streaming uses bounded audio/text queues and incremental checkpoints rather than rewriting the whole transcript on every update. Saved audio and transcripts still consume disk space; recordings are retained until you delete them, and low disk space stops capture safely.

Each mode remembers its own model. Select the mode, open **Models**, then **Install** and **Use**. Streaming offers **Nemotron 3.5 8-bit, Nemotron 3.5 BF16, and Voxtral Realtime 4-bit**: three precision choices across two 2026 model families. Nemotron 8-bit remains the starting choice. Mode/model changes are blocked while recording or finalizing. Quiet intervals pause recognition, not capture; the gate measures volume, not whether background sound is speech. Saved streaming audio can be replayed for clipboard-only recovery.

Successful model output is accepted, including no text. Empty recognition is not an error; Retry is for actual execution failures, not pauses or suspected missing words. Transcription accuracy depends on the selected model.

## Measured performance

**[Open the sortable benchmark table ↗](https://tobynoskillson.github.io/Vella/)**

The two error columns answer different questions. **Lower is better for both.**

- **Word-only error** (“Words” in the menu): how many words were wrong, missing or added. It ignores punctuation and capitals. This is word error rate, or WER.
- **Full-text error** (“Text” in the menu): how closely the finished transcript matches the reference, **including punctuation and capitals**. It counts edits per character, not per word. This is character error rate, or CER.

**Sorted by full-text error, lowest first**—the same default used in the app. That makes punctuation and capitalization part of the comparison, rather than ranking on word recognition alone.

Recorded on **Apple M5 Max · 128 GiB RAM**, using 144 English reading clips from 34 speakers (20m 15s). ★ marks a Dictation recommendation. † marks a batch-benchmarked candidate outside the Dictation catalog; native Streaming measurements appear separately below.

### Dictation / batch inference

<!-- BENCHMARK_RESULTS_START -->

| Model | Word-only error | Full-text error ↓ | Warm speed | Warm MLX memory |
|---|---:|---:|---:|---:|
| [Parakeet v3 4-bit](https://huggingface.co/animaslabs/parakeet-tdt-0.6b-v3-mlx-4bit) ★ | 1.54% | 1.77% | 233.7× | 1.34 GB |
| [Parakeet v3 8-bit](https://huggingface.co/animaslabs/parakeet-tdt-0.6b-v3-mlx-8bit) | 1.60% | 1.85% | 237.4× | 1.61 GB |
| [Qwen3 0.6B 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit) † | 1.54% | 2.07% | 88.6× | 1.93 GB |
| [Qwen3 1.7B BF16](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16) | 1.41% | 2.08% | 30.5× | 5.50 GB |
| [Qwen3 1.7B 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit) ★ | 1.51% | 2.12% | 59.5× | 3.03 GB |
| [Qwen3 1.7B 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | 1.57% | 2.14% | 44.5× | 3.89 GB |
| [Nemotron 3.5 ASR 0.6B 8-bit](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit) † | 2.64% | 2.53% | 52.9× | 0.99 GB |
| [Voxtral Mini Realtime 4B 4-bit](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit) † | 2.26% | 2.57% | 5.1× | 5.94 GB |
| [Whisper large-v3 8-bit](https://huggingface.co/mlx-community/whisper-large-v3-8bit) ★ | 2.60% | 4.50% | 21.0× | 2.52 GB |
| [Granite 4.0 1B 4-bit](https://huggingface.co/mlx-community/granite-4.0-1b-speech-4bit) ★ | 1.29% | 4.61% | 44.1× | 7.64 GB |
| [Granite 4.0 1B 8-bit](https://huggingface.co/mlx-community/granite-4.0-1b-speech-8bit) | 1.19% | 4.61% | 37.4× | 8.56 GB |
| [Whisper large-v3 FP16](https://huggingface.co/mlx-community/whisper-large-v3-asr-fp16) | 2.82% | 4.76% | 19.7× | 4.03 GB |
| [SenseVoice FP32](https://huggingface.co/mlx-community/SenseVoiceSmall) ★ | 2.45% | 5.05% | 631.6× | 1.79 GB |
| [SenseVoice 4-bit](https://huggingface.co/vanch007/SenseVoiceSmall-4bit) | 3.45% | 5.40% | 582.3× | 0.88 GB |
| [Granite Speech 5.0 TurboCTC 470M FP16](https://huggingface.co/iky1e/granite-speech-5.0-470m-turboctc-mlx-fp16) † | 3.70% | 5.87% | 654.0× | 1.59 GB |
| [Whisper large-v3 4-bit](https://huggingface.co/mlx-community/whisper-large-v3-asr-4bit) | 4.14% | 6.30% | 22.2× | 1.75 GB |

<!-- BENCHMARK_RESULTS_END -->

Speed compares audio length with transcription time after the model is loaded; 60× means a minute of audio takes about a second of inference. Memory is the measured MLX allocation, **not total app memory**. Accuracy and speed use two passes per clip; memory was measured separately. These are clean-reading results, not a guarantee for every voice or noisy room.

[Full measurements](Resources/ReferenceResults/) · [How the scores are calculated](Resources/benchmark-policy.json)

### Streaming / native incremental input

**The same 144 clips, audio hashes, references and scoring as the table above**, fed through Vella's actual streaming worker in 100-ms packets. Two timing passes per clip. Nemotron uses its supported 320-ms context; Voxtral uses a configured 480-ms delay. Neither setting is measured microphone-to-word latency.

<!-- STREAMING_RESULTS_START -->

| Model | Word-only error | Full-text error ↓ | Streaming compute speed | Warm MLX memory |
|---|---:|---:|---:|---:|
| [Nemotron 3.5 ASR 0.6B 8-bit](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit) | 2.95% | 2.66% | 15.3× | 0.98 GB |
| [Nemotron 3.5 ASR 0.6B BF16](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b) | 2.86% | 2.66% | 8.1× | 2.22 GB |
| [Voxtral Mini Realtime 4B 4-bit](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit) | 2.35% | 2.71% | 1.2× | 5.56 GB ‡ |

<!-- STREAMING_RESULTS_END -->

‡ Voxtral's warm MLX peak was measured during its completed two-pass timing run, not a separate memory profile. Nemotron memory uses separate full-suite one-pass measurements. All values are actual MLX allocation peaks, not total process RAM.

On this corpus, Nemotron 8-bit is the efficient starting choice. BF16 changes a few words without lowering full-text error; Voxtral improves word recognition but runs only slightly faster than real time.

Streaming speed is accelerated compute throughput, excluding loading, IPC and inter-clip reset—not how quickly words appear after you speak. Accuracy includes the normal streaming gate, partials and final flush; these are not the batch scores reused under another label. This clean-English corpus does not establish multilingual accuracy or day-long microphone endurance.

The September 2026 VibeVoice streaming release and Moonshine v2 were screened but not benchmarked: Vella's pinned MLX runtime lacks their native input-streaming implementations. Moonshine's current official engine would require a separate runtime integration. No untested scores or placeholder model choices are included.

## Your recordings

Transcription works offline once you've downloaded a model. **Vella stores recordings and transcripts locally until you delete them**, even after a successful paste. Vella does not upload them; apps you insert text into may sync or send that text according to their own settings. Choose **Open Saved Recordings** to find them.

There's no recording timer, but you'll need enough disk space. If transcription fails, your saved audio is there to retry. Clipboard managers and Universal Clipboard can still see text you copy or paste.

To uninstall, quit Vella and move the app to Trash. Your recordings and models remain in `~/Library/Application Support/Vella`; delete that folder separately only if you want to remove them too.

---

[Releases](https://github.com/TobyNoSkillSon/Vella/releases) · [Interactive benchmarks](https://tobynoskillson.github.io/Vella/) · [Raw results](Resources/ReferenceResults/) · [Developer guide](Resources/AGENT_GUIDE.md) · [Apache 2.0 license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
