# Vella user guide

[Back to Vella](../README.md)

## Install or update

```sh
git clone https://github.com/TobyNoSkillSon/Vella && cd Vella
scripts/install.sh            # later: git pull && scripts/install.sh
```

Requirements: an Apple Silicon Mac with macOS 14 or newer. The prebuilt app needs no Xcode, Python or developer account.

What `scripts/install.sh` does, in order:

1. Downloads `Vella-<version>-arm64.zip` and `SHA256SUMS` for the version in this checkout with curl (never a browser, which would quarantine the app).
2. Verifies before touching anything: the exact checksum line for the zip, that the archive holds only `Vella.app` with its helpers and Metal library, that the app's version is the one requested, and its code signature. `scripts/install-release.sh <version> --dry-run` stops here.
3. Refuses, leaving everything unchanged, while Vella is recording, transcribing or loading a model.
4. Quits a running Vella, copies the new app beside the old one, verifies it again and swaps it in. If the swap fails the old app is restored. A certificate-signed installation is only replaced by an app with the same signing identity, so macOS privacy permissions carry over.
5. Starts Vella and waits until it is ready: the app has written its status, nothing is loading, and every model you keep loaded at launch is loaded (a fresh install has none). It prints `ready: …`. Only then is the previous app deleted; if Vella is not ready within 30 minutes, the previous app is kept and its path printed.

Models, recordings and settings in `~/Library/Application Support/Vella` are kept. The whole app bundle is replaced, so files from older versions never linger inside it. The checksum detects a corrupted download; it comes from the same release, so it is not a signature.

`VELLA_BUILD=source scripts/install.sh` builds this checkout instead (Command Line Tools Swift, full Xcode and its Metal Toolchain; the installer prints the command that fixes a missing one) and installs it the same way.

## First run

1. Open Vella and approve Microphone and Accessibility access when asked.
2. Press **Control + Command + N** to record. Click your destination field, then press the shortcut again to finish.

A fresh install has no model. If you dictate before getting one, Vella keeps the recording and the menu shows **Get <recommended model> (<size>)**. Click it: the model downloads from Hugging Face, and the waiting recording is transcribed when it is ready. Nothing downloads without that click. After that, transcription works offline.

## Menu

1. **Status** — `Vella: ready`, the loaded model and one fact line. Green when ready, grey while loading or downloading, orange when a helper failed (click it for the error and the log).
2. **Mode** (Dictation or Streaming) · **Microphone** · **Shortcuts**.
3. **Models…** · **Keep Hot** · **Memory**.
4. **Copy Last Transcript** (and recovery of an unfinished one) · **Open Vella Files** · **Restart Worker** · **Launch at Login**.
5. **Support the developer…** · **Quit Vella**.

Hover an item for what it does.

## Models

**Models…** opens one table with a Dictation section and a Streaming section. Each row is one model:

| Column | Meaning |
|---|---|
| Model | Name; under a loaded model, its engine (**Optimized · <chip>** or **MLX**). Tooltip: parameters, native precision, licence. |
| Languages | Supported languages. |
| Params | Parameter count. |
| Precision | Segmented control with the precisions this model offers (`4b`, `8b`, `BF16`, `FP16`, `FP32`, as its weights allow; never below 4 bits). The recommended precision is green. |
| WER | Word error rate on Vella's benchmark: wrong, missing or extra words, ignoring case and punctuation. Tooltip: word error rate per language. |
| Format | Character error rate with case and punctuation kept. |
| Speed | Audio length ÷ transcription time, after loading (× real time). |
| J / min | Joules per minute of audio, whole chip, idle subtracted. |
| Memory | Loaded footprint. |
| On disk | Downloaded size, `—` if not downloaded. |

Lower is better for WER, Format, J / min and Memory; higher for Speed. `—` means not measured at that precision; Vella never estimates a figure. Every figure's tooltip says when and on which Mac it was measured. On a Mac with a different chip family, the footer says `Benchmarks measured on M5 Max`: speed, energy and memory differ on your Mac; accuracy does not.

**Recommended precision.** Among a model's measured precisions whose WER is within 0.5 points of its native precision, the one with the lowest J / min (ties: faster, then more bits). A model loads at the selected precision, which starts as the recommended one. Selecting another precision only records the choice and shows its figures with the difference from the recommended one beneath (green better, red worse). On a loaded model with another precision selected, the button is a green **Reload**, which loads the selection in place of the loaded one.

**Actions.** **Get** downloads the model. **Load** loads it and keeps it loaded (see Keep Hot); **Unload** frees its memory and keeps the download. The trash icon deletes the downloaded weights after confirmation. Recordings and transcripts are never deleted with a model.

**Engine.** **Optimized · <chip>** means Vella's optimized kernels for this model passed a self-test against the stock MLX path on this Mac, in a separate process, when the model loaded; the result is remembered for this model, GPU, macOS version and app version. **MLX** means the stock path: same model, slower. The tooltip lists which parts are optimized. If an optimized transcription fails or produces invalid numbers, Vella transcribes that recording again on the stock path and keeps the model on it until it is reloaded.

The footer's **Want another model? Copy a request for your agent.** copies a brief for a coding agent. Nothing is sent anywhere.

## Keep Hot

How long an idle model stays loaded, timed per model from its last use. The next dictation that needs an unloaded model loads it again.

- **Manually loaded** (Load or Reload in the table): Always (default), 5, 15, 30 or 60 min. These form the launch set: they load again when Vella starts. Unload or delete removes a model from it.
- **Loaded on demand** (a dictation needed a model that was not loaded): 15 min (default), 5, 30, 60 min or Always. On-demand loads never join the launch set.

## Memory

- **Fit in free memory** (default): before each load, Vella compares the model's measured memory (plus headroom) with the memory macOS can hand out without swapping. If it does not fit, Vella unloads idle models to make room, on-demand ones first and least recently used first, never the one a recording is waiting for. If even that cannot free enough, nothing is unloaded and the load is refused with the numbers and the ways out, for example `Qwen3 ASR 1.7B at BF16 needs ~4.6 GB; ~0.9 GB free without swapping. Unload Parakeet v3, pick 8b, or allow swap in Vella → Memory.` The check is best effort at load time, not a guarantee: other apps can still push macOS into swap.
- **Allow swap (slower)**: skip the check. macOS moves data to disk, and everything on the Mac can slow down.

The submenu shows `~X GB free now`.

## Everyday dictation

- A small waveform appears while you speak. Longer jobs also show an estimated time remaining.
- Vella pastes the finished text but never presses Enter or Send.
- Dictation uses the field focused when you finish, with a final safety check before pasting. You can roam apps and Spaces while recording, then click your destination before stopping.
- If you change the selected window or field after Finish but before insertion, Vella leaves the text on your clipboard instead of pasting to the wrong place.
- Terminal and custom-editor acceptance depends on the target application.
- There is no recording timer, but you need enough disk space.

## Dictation and Streaming

Choose **Mode → Dictation / Streaming**. Both modes use your configured activation, **⌃⌘N** by default.

- **Dictation** transcribes and inserts after you finish.
- **Streaming** inserts text continuously wherever keyboard focus is, using native incremental recognition. Finish sends only the remaining suffix, never a duplicate full transcript.

Streaming is deliberately blind and roaming:

- Window changes, field changes, clicks, and manual typing do not stop it.
- Vella does not bind words to a field or utterance. Words still being processed when you switch focus go to the new focus.
- Pause your speech or close the microphone while navigating as needed.
- Streaming sends native Unicode text without touching the clipboard and without pressing Enter.
- Whitespace and control characters are normalized; already sent text is never rewritten to fix an earlier prefix.

Dictation keeps its finish-only checks: frozen Finish-time destination, rechecked immediately before paste, clipboard fallback when focus is missing or changed.

Quiet intervals pause recognition, not capture. The gate measures volume, not whether background sound is speech. Recording continues through silence.

Streaming uses bounded audio and text queues plus incremental checkpoints rather than rescanning or rewriting the whole transcript on every update. Audio and model caches stay bounded; saved recordings and transcripts necessarily grow with speech. Saved streaming audio can be replayed for clipboard-only recovery through the original streaming model.

Mode and model changes are blocked while recording or finalizing.

## Shortcuts

<p align="center">
  <img src="images/shortcuts-current.png" alt="Shortcuts menu with Toggle, Hold to Talk, Tap or Hold, key chords, modifier-only and mouse-button options" width="254">
  <img src="images/mouse-current.png" alt="Mouse-button menu with the red inline prompt to press side button 4 to confirm" width="452">
</p>

**Shortcuts** sits directly below **Microphone**. You can choose:

- A key combination.
- A left or right modifier key used alone.
- A middle or side mouse button. The primary and secondary buttons remain ordinary clicks.

Behaviors:

- **Toggle:** activate once to start and again to finish.
- **Hold to Talk:** hold to record, release to finish.
- **Tap or Hold:** a short tap toggles recording; holding for at least 300 ms finishes on release.

Registering a key chord uses the normal global-shortcut path without Accessibility access; inserting text still requires it. Modifier-only and mouse bindings also require Accessibility access for input observation. Simply launching Vella does not prompt for these optional input bindings. If permission or registration fails, Vella shows the error and keeps your working shortcut; it does not silently replace it.

Modifier-only notes:

- Triggers fire only when the modifier is used alone. A brief guard precedes hold activation so normal key combinations do not start recording.
- Typing or pressing another modifier cancels a pending solo press.
- Left and right are distinct choices.
- Fn availability depends on the keyboard and macOS settings. If Fn does not fire, prefer another binding.

Mouse confirmation:

- Selecting a mouse button never applies it immediately. The same menu row shows a red confirmation prompt such as “Press middle button to confirm…”.
- Press and release the requested button once to save it. The confirming click does not start recording.
- A different button adds feedback such as “Button 5 detected” while Vella keeps waiting for the requested button.
- If no matching click arrives within 10 seconds, the row reports that the button was not detected and your previous shortcut is unchanged.
- Closing the menu cancels confirmation.
- Starting capture also cancels a pending confirmation.
- Mouse remapping software may prevent a standard button event from reaching Vella; a timeout alone cannot identify the cause.
- If observation fails, the row reports either missing Accessibility access or that input could not be observed, without claiming a hardware cause. Commit failures keep the compact “Shortcut unchanged” text; the full diagnostic stays in the tooltip.

Shortcut changes are disabled during capture and processing. **Reset to Default** restores **⌃⌘N · Toggle**. Model and microphone choices are unchanged. If the stored chord is already reserved by another app, Vella reports it on launch rather than taking it over.

## When little or no text appears

Successful model output is accepted, including no text. Empty recognition is not an error.

- When the model returns no text, audio remains saved and Vella does not erase the clipboard or type anything. Quiet audio can still produce model errors or hallucinated text; Vella does not independently classify it as speech or silence.
- Retry is for actual execution failures, not pauses or suspected missing words.
- If transcription fails, your saved audio is there to retry. Failed jobs preserve their unfinished work.

## Recordings, disk, recovery, and privacy

- Vella stores recordings and transcripts locally until you delete them, even after a successful paste. Choose **Open Vella Files** to find them.
- If disk space runs low, capture stops safely and saved audio is kept. Free space before continuing.
- Recording metadata is written first so an interrupted session stays recoverable. Integrity failures preserve files for recovery rather than silently discarding them. Streaming retries archive the previous event journal first.
- Vella does not upload recordings or transcripts. Apps you insert text into may sync or send that text according to their own settings.
- Clipboard managers and Universal Clipboard can still see text you copy or paste. Streaming live insertion avoids the clipboard per chunk; Dictation paste and recovery use the clipboard path described above.
- Model downloads (when you choose **Get**) are the only expected network transfer during normal use, plus the release check described above. The recognition helpers run in a sandbox that denies all network access; downloads are a separate helper, `VellaModelTool`.

## Update notices

Vella never installs updates automatically, and update checks need no additional permissions.

Exact behavior:

- Checked only after a completed transcription.
- Checked only if no check has been attempted that calendar day.
- The last attempt and a detected update are remembered across restarts.
- There is no startup request and no polling timer.
- A newer stable release turns the menu-bar icon yellow and adds a yellow **Update available…** entry immediately above **Support the developer…**.
- Choosing it opens that release page in your browser.
- Offline or failed checks are silent and do not clear a known update.
- The indicator remains until you install that version or newer.
- Draft and prerelease versions are ignored.

Privacy: GitHub receives a normal HTTPS request to check the latest stable release tag. Vella never sends audio or transcripts. The request goes to the public release endpoint only.

## Uninstall

1. Quit Vella.
2. Move `~/Applications/Vella.app` to the Trash.
3. Models, settings and recordings remain in `~/Library/Application Support/Vella`. Delete that folder separately only if you want them gone too.

## Further reading

- [README](../README.md) — what Vella does, the model table, install.
- [AGENTS.md](../AGENTS.md) — the install steps for a coding agent.
- [Model integration guide](../Resources/AGENT_GUIDE.md) — what a new model needs before Vella can offer it.
- [License](../LICENSE) and [third-party notices](../THIRD_PARTY_NOTICES.md).
