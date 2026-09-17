# Vella user guide

[Back to Vella](../README.md)

## Install or update

Use the install command in [README](../README.md). The stable URL currently serves **v0.8.8** and may advance after a future verified release; rerunning it retries or installs the current stable version.

To inspect before running, or to pin **v0.8.8**:

```sh
installer="$(mktemp)"
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.8.8/scripts/install.sh -o "$installer"
```

Inspect the file with `less "$installer"`. To install after reviewing it, run `bash < "$installer"`, then remove the temporary file with `rm -f "$installer"`. Reading it through stdin selects the release-download path rather than treating the file as a source checkout.

Or pipe the pinned script directly:

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/TobyNoSkillSon/Vella/v0.8.8/scripts/install.sh | bash
```

Requirements:

- Apple Silicon Mac running macOS 14 or newer.
- Apple's free Command Line Tools.
- Python 3.12–3.14.

If either is missing, the installer tells you how to install it. No paid developer membership is needed.

What the installer does:

- Builds Vella and puts it in `~/Applications`.
- Checks the selected Apple tools before building.
- Verifies the source archive.
- Preserves existing models, recordings, microphone choices, and settings during updates.
- Does not change your selected toolchain.
- Does not disable macOS security checks.
- Certificate-signed installations are left alone; this route creates ad-hoc builds.

Before updating, finish any recording or transcription.

Checksums detect archive corruption or mismatches; they do not independently authenticate the downloaded bootstrap script.

Vella is a beta. macOS will ask for Microphone and Accessibility access, and you may need to approve permissions again after an update. Ad-hoc updates can require renewed privacy approval.

## First run and models

A new installation automatically downloads and selects **Parakeet Q4** (about 637 MB) for Dictation. Existing installations retain their model choices.

1. Open Vella and approve Microphone and Accessibility access when requested.
2. Press **Control + Command + N** to record. Click your destination text field, then press the shortcut again to finish.
3. For live transcription, choose **Mode → Streaming**, then **Models** to install and select a supported Streaming model. You can also change the Dictation model there.

Model downloads come directly from Hugging Face without opening a browser. The **Install** button shows download size, source, and license; selecting a model for use is a separate **Use** step. Failed or interrupted downloads remain resumable, and partial weights are never selected. Cancellation leaves your current selection unchanged.

Transcription works offline once you have downloaded a model.

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

## Everyday dictation

- A small waveform appears while you speak. Longer jobs also show an estimated time remaining.
- Vella pastes the finished text but never presses Enter or Send.
- Dictation uses the field focused when you finish, with a final safety check before pasting. You can roam apps and Spaces while recording, then click your destination before stopping.
- If you change the selected window or field after Finish but before insertion, Vella leaves the text on your clipboard instead of pasting to the wrong place.
- Terminal and custom-editor acceptance depends on the target application.
- There is no recording timer, but you need enough disk space.

## Shortcuts

These options are in the current source checkout. The pinned v0.8.8 installer does not include them yet.

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

## Model choices

Each mode remembers its own model. Select the mode first, open **Models**, then **Install** and **Use**.

- Dictation starts with Parakeet Q4 on a new installation.
- Streaming offers **Nemotron 3.5 8-bit, Nemotron 3.5 BF16, and Voxtral Realtime 4-bit**: three precision choices across two 2026 model families. Nemotron 8-bit remains the starting choice.
- Only qualified native incremental architectures are offered for Streaming. Batch dictation scores do not measure live streaming latency or accuracy, and a configured context or delay number is not microphone-to-word latency.
- On the shared clean-English reference suite, BF16 changes a few words without lowering full-text error relative to Nemotron 8-bit, at higher memory and slower compute. Voxtral improves word recognition on that corpus but runs only slightly faster than real time, leaving limited headroom for live use.
- Transcription accuracy belongs to the selected model.

The Models table shows recommended variants plus installed or imported models so they remain manageable. Unfinished downloads in Vella-owned folders appear as Resume. External, shared, linked, active, or in-use model files are protected; the delete control explains why when deletion is blocked. Deleting an installed model moves its local files to Trash; recordings, transcripts, and reference scores are kept. Empty Trash to reclaim disk space.

For benchmark numbers and scoring definitions, see [README](../README.md), the [interactive benchmarks](https://tobynoskillson.github.io/Vella/), [raw results](../Resources/ReferenceResults/), and [how scores are calculated](../Resources/benchmark-policy.json). This guide does not duplicate those tables. For Streaming, the app hides measurements made with a different worker version; the website retains the dated source records.

## When little or no text appears

Successful model output is accepted, including no text. Empty recognition is not an error.

- When the model returns no text, audio remains saved and Vella does not erase the clipboard or type anything. Quiet audio can still produce model errors or hallucinated text; Vella does not independently classify it as speech or silence.
- Retry is for actual execution failures, not pauses or suspected missing words.
- If transcription fails, your saved audio is there to retry. Failed jobs preserve their unfinished work.

## Recordings, disk, recovery, and privacy

- Vella stores recordings and transcripts locally until you delete them, even after a successful paste. Choose **Open Saved Recordings** to find them.
- If disk space runs low, capture stops safely and saved audio is kept. Free space before continuing.
- Recording metadata is written first so an interrupted session stays recoverable. Integrity failures preserve files for recovery rather than silently discarding them. Streaming retries archive the previous event journal first.
- Vella does not upload recordings or transcripts. Apps you insert text into may sync or send that text according to their own settings.
- Clipboard managers and Universal Clipboard can still see text you copy or paste. Streaming live insertion avoids the clipboard per chunk; Dictation paste and recovery use the clipboard path described above.
- Model downloads are the only expected network transfer during normal use, plus the lightweight release-tag check described above. Inference dependencies run in Vella's isolated local runtime with telemetry and offline Hub flags set.

## Uninstall

1. Quit Vella.
2. Move the app to Trash.
3. Your recordings and models remain in `~/Library/Application Support/Vella`. Delete that folder separately only if you want to remove them too.

## Further reading

- [README](../README.md) — install command, interface previews, measured performance.
- [Interactive benchmarks](https://tobynoskillson.github.io/Vella/) — sortable accuracy, speed, and memory table.
- [Raw results](../Resources/ReferenceResults/) — published reference measurements.
- [How scores are calculated](../Resources/benchmark-policy.json) — benchmark suite and scoring policy.
- [Model integration guide](../Resources/AGENT_GUIDE.md) — compatibility and setup notes for adding models.
- [License](../LICENSE) and [third-party notices](../THIRD_PARTY_NOTICES.md).
