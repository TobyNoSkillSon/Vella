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
5. Starts Vella and waits until it is ready: the app has written its status, nothing is loading, and every model you keep loaded at launch is loaded (a fresh install has none). It prints `ready: …`. Only then is the previous app deleted; if Vella is not ready within 30 minutes, or it runs but a model you keep loaded could not load (`degraded: …`), the previous app is kept and its path printed. `VELLA_ACCEPT_DEGRADED=1` makes a degraded install exit 0; the previous app is still kept.

The installer also links the `vella` command into `~/.local/bin` (see **Transcribe files** below).

Models, recordings and settings in `~/Library/Application Support/Vella` are kept. The whole app bundle is replaced, so files from older versions never linger inside it. The checksum detects a corrupted download; it comes from the same release, so it is not a signature.

`VELLA_BUILD=source scripts/install.sh` builds this checkout instead (Command Line Tools Swift, full Xcode and its Metal Toolchain; the installer prints the command that fixes a missing one) and installs it the same way.

## First run

1. Open Vella and approve Microphone and Accessibility access when asked.
2. Press **Control + Command + N** to record. Click your destination field, then press the shortcut again to finish.

A fresh install has no model. If you dictate before getting one, Vella keeps the recording and the menu shows **Get <recommended model> (<size>)**. Click it and confirm the download (see **Downloads** below): the model downloads from Hugging Face, and the waiting recording is transcribed when it is ready. Nothing downloads without that confirmation. After that, transcription works offline.

## Menu

1. **Status** — `Vella: ready`, the loaded model and one fact line. Green when ready, grey while loading or downloading, orange when a helper failed (click it for the error and the log).
2. **Mode** (Dictation or Streaming) · **Microphone** · **Shortcuts**.
3. **Models…** · **Keep Hot** · **Memory**.
4. **Copy Last Transcript** (and recovery of an unfinished one) · **Copy Skill for Your Agent** · **Copy Diagnostics** · **Open Vella Files** · **Restart Worker** · **Launch at Login**.
5. **Support the developer…** · **Quit Vella**.

Hover an item for what it does.

## Models

**Models…** opens one table with a Dictation section and a Streaming section. Each row is one model:

| Column | Meaning |
|---|---|
| Model | Name; under a loaded model, its engine (**Optimized · <chip>** or **MLX**). Tooltip: parameters, native precision, licence. |
| Languages | Supported languages. |
| Params | Parameter count. |
| Q | Bits per weight, as a segmented control: 32 (FP32), 16 (BF16), 8 and 4 (quantized), or FP16 by name for an FP16 model (an older Whisper install), from the model's native precision down, never below 4. The recommended one is green. Each segment's tooltip names the exact format and whether it is published or made on this Mac from the higher precision. |
| WER | Word error rate on Vella's benchmark: the percentage of words wrong (substituted, missed or added) out of the words spoken, ignoring case and punctuation. The industry-standard metric, as on the Hugging Face Open ASR Leaderboard; Vella's v2 set is hard (meetings, far-field microphones, accents, earnings calls), so its rates run higher. Tooltip: word error rate per language. |
| Format | Vella's own measure of finished text: character error rate with case and punctuation kept. No industry standard exists for it. |
| Speed | Real-time factor (RTFx): audio seconds per processing second, after loading. |
| J / min | Joules per minute of audio, whole chip, idle subtracted. |
| Memory | Loaded footprint. |
| On disk | Download size (dimmed until downloaded). For a precision made on this Mac, its measured size, else `—`. |

Lower is better for WER, Format, J / min and Memory; higher for Speed. `—` means not measured at that precision; Vella never estimates a figure for a local model. The greyed cloud rows in Dictation (ElevenLabs Scribe v2, Microsoft Azure Speech) are for comparison only: Vella never sends audio to them, and their WER (`~13%`) is estimated from the Hugging Face Open ASR Leaderboard, not measured; the tooltip gives the source and range. Clicking a heading sorts by each model's best value across its precisions, so rows keep their place when you switch precision; models with nothing measured come last. Every figure's tooltip says when and on which Mac it was measured. On a Mac with a different chip family, the footer says `Benchmarks measured on M5 Max`: speed, energy and memory differ on your Mac; accuracy does not.

**Recommended precision.** Among a model's measured precisions whose WER is within 0.5 points of its native precision, the one with the lowest J / min (ties: faster, then more bits).

**One precision per model.** A loaded model's row always shows the precision it is loaded at, with **Unload**. An unloaded row shows the precision it was last loaded at, else the recommended one, with **Load** (or **Get** when it is not downloaded). Clicking another segment is a preview: the row shows that precision's figures, with the difference from the recommended one beneath (green better, red worse), and on a loaded model a green **Reload**, which loads it in place of the loaded one. Closing the menu without Reload discards the preview. Only Load and Reload change the model: the one last loaded for a mode is the one its next dictation (or streaming session) loads, so the table and dictation always agree.

**Made on this Mac.** Precisions the model's authors do not publish (for example 16 for Parakeet v3, 8 and 4 for Parakeet v3 Ultra) are made on your Mac from the higher precision when the model loads. Until they are measured their figures show `—`. Getting such a precision downloads the weights it is made from; deleting those weights removes it too, so while it is your dictation or streaming model, choose another one first.

**Actions.** **Get** downloads the model and loads it. **Load** loads it and keeps it loaded (see Keep Hot); **Unload** frees its memory and keeps the download. The trash icon deletes the downloaded weights after confirmation. Recordings and transcripts are never deleted with a model.

**Downloads.** Every action that needs a download (Get, Load or Reload of a precision that is not on disk, a precision made on this Mac whose source is missing, the first-dictation Get) first asks in a popup: which model and precision, whether it is published on Hugging Face (repository and revision) or made on this Mac from which weights, the exact download size, the disk space needed and free, and that it loads when done. **Cancel** is the default; nothing downloads without **Download**. The footer shows the progress; a failed or stalled download shows its reason there. A cancelled or failed download removes its partial files, and when Vella starts it deletes partial downloads left in its Models folder by a quit or crash.

**Engine.** **Optimized · <chip>** means Vella's optimized kernels for this model passed a self-test against the stock MLX path on this Mac, in a separate process, when the model loaded; the result is remembered for this model, GPU, macOS version and app version. **MLX** means the stock path: same model, slower. The tooltip lists which parts are optimized. If an optimized transcription fails or produces invalid numbers, Vella transcribes that recording again on the stock path and keeps the model on it until it is reloaded.

The footer's **Want another model? Copy a request for your agent.** copies a brief for a coding agent. Nothing is sent anywhere.

## Keep Hot

How long an idle model stays loaded, timed per model from its last use. The next dictation that needs an unloaded model loads it again.

- **Manually loaded** (Load or Reload in the table): Always (default), 5, 15, 30 or 60 min. These form the launch set: they load again when Vella starts. Unload or delete removes a model from it.
- **Loaded on demand** (a dictation needed a model that was not loaded): 15 min (default), 5, 30, 60 min or Always. On-demand loads never join the launch set.

## Memory

- **Fit in free memory** (default): before each load, Vella compares the model's measured memory (plus headroom) with the memory macOS can hand out without swapping. If it does not fit, Vella unloads idle models to make room, on-demand ones first and least recently used first, never the one a recording is waiting for. If even that cannot free enough, nothing is unloaded and the load is refused with the numbers and the ways out, for example `Qwen3 ASR 1.7B at BF16 needs ~4.6 GB; ~0.9 GB free without swapping. Unload Parakeet v3, pick 8-bit, or allow swap in Vella → Memory.` The check is best effort at load time, not a guarantee: other apps can still push macOS into swap.
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

## Transcribe files: command line and API

Vella transcribes audio files with the same models, offline. It reads anything macOS decodes (WAV, MP3, M4A/AAC, FLAC, CAF, AIFF), up to 3 hours per file, converts it to 16 kHz mono and cuts it into 5–25 s segments at pauses, like a dictation.

```sh
vella transcribe talk.m4a                        # the transcript
vella transcribe talk.m4a --srt > talk.srt       # subtitles; also --vtt, --json, --verbose-json (timed segments)
vella transcribe talk.m4a --model parakeet-v3    # another downloaded model
vella models                                     # models usable now, one per line
vella status                                     # one line: running, loaded models, API address
vella skill --install ~/.agents/skills           # the agent skill (writes transcribe/SKILL.md)
vella diagnose                                   # a report for bug reports (see Reporting a problem)
```

`vella` starts Vella if it is not running. Transcripts are printed only: never pasted, copied or added to your saved recordings. The file's audio is converted in a private temporary folder that is removed when the request ends.

**Your dictation goes first.** A file waits while you record or while a dictation is being transcribed; a dictation that finishes during a file waits for at most the one segment in progress (usually well under a second). Files are processed one at a time; up to eight more wait in line.

**Models.** Without `--model`, a file uses your current dictation model. Another model loads on demand at the precision shown in **Models…** and unloads after its **Keep Hot** time, like any on-demand load. It never unloads your dictation model to make room: if memory is short the request is refused with the numbers. Nothing downloads through the command or the API; get models in **Models…**. Streaming models are not used for files.

**The API.** The app serves an OpenAI-compatible API on `127.0.0.1` at a port chosen at launch (`vella url` prints the base URL; it changes when Vella restarts). Code written for OpenAI's transcription endpoint works with only the base URL changed:

```sh
curl -s "$(vella url)/audio/transcriptions" -F file=@talk.m4a -F model=whisper-1 -F response_format=text
```

```python
from openai import OpenAI
import subprocess
client = OpenAI(base_url=subprocess.check_output(["vella", "url"], text=True).strip(), api_key="local")
with open("talk.m4a", "rb") as f:
    result = client.audio.transcriptions.create(model="whisper-1", file=f, response_format="verbose_json")
print(result.text, [(s.start, s.end) for s in result.segments])
```

| Route | What it does |
|---|---|
| `POST /v1/audio/transcriptions` | multipart/form-data: `file` (required), `model`, `response_format` (`json` default, `text`, `verbose_json`, `srt`, `vtt`), `language`, `prompt`, `temperature`, `timestamp_granularities[]`. |
| `GET /v1/models`, `GET /v1/models/{id}` | Dictation models whose files are on this Mac, with `precision`, `loaded` and `current`. |
| `GET /status` | `"api": 1`, version, pid, port, dictation state, the current dictation model, loaded models, memory, and the API queue. |

- `model`: a model id from `/v1/models`; `whisper-1` (what OpenAI examples send), an empty value or `current` means your current dictation model.
- `language` is echoed in `verbose_json`; the models detect the language themselves. `prompt` and `temperature` are accepted and ignored (decoding is greedy). Timestamps are per segment; word timestamps are not provided. There is no streaming response and no translation endpoint.
- The key is ignored, but SDKs need one: pass any string.
- Errors use OpenAI's shape, `{"error": {"message", "type", "param", "code"}}`: 400 invalid request, 404 unknown or not downloaded model (`model_not_found`), 413 over 200 MB, 429 queue full (at most nine uploads, 1 GB in total, are received or waiting at once), 503 too many open connections, 507 not enough free memory (`insufficient_memory`) or disk (an upload must leave 2 GB free for recordings). A client that has not sent its request headers within 10 s, or pauses for 30 s while sending its body, is disconnected.
- Uploads are limited to 200 MB. A JSON body `{"path": "/absolute/file.m4a", …}` with the same fields transcribes a local file without uploading it (this is what `vella` does); it needs the header `X-Vella-Token` set to `api_token` from `worker-status.json`, so an app that cannot read Vella's files (a sandboxed one) cannot make Vella read yours.
- Security: it listens on the IPv4 loopback address only. Requests with an `Origin` header (web pages) or a `Host` other than `127.0.0.1:<port>`/`localhost:<port>` get 403, and POST bodies other than multipart/form-data or JSON get 415, all before any of the body is read. The port and API version are in `~/Library/Application Support/Vella/worker-status.json` (`api_port`, `api`).

## When little or no text appears

Successful model output is accepted, including no text. Empty recognition is not an error.

- When the model returns no text, audio remains saved and Vella does not erase the clipboard or type anything. Quiet audio can still produce model errors or hallucinated text; Vella does not independently classify it as speech or silence.
- Retry is for actual execution failures, not pauses or suspected missing words.
- If transcription fails, your saved audio is there to retry. Failed jobs preserve their unfinished work.

## Reporting a problem

**Copy Diagnostics** in the menu, or `vella diagnose` in Terminal, prints one screen for a bug report and ends with a link that opens a prefilled GitHub issue:

- this Mac: chip, model, memory, macOS and its build, and the GPU family the optimized kernels are checked against;
- the versions of Vella, its `vella` command, its API and its recognition helpers;
- each loaded model: its engine (**Optimized** or **MLX**), precision and Keep Hot class, which parts run optimized, and every reason a part runs on the stock path;
- the optimized-path self-test verdicts saved on this Mac, with the reason for each one that is not optimized;
- each loaded Dictation model timed on the five short clips built into Vella (public LibriSpeech recordings, 23 s in all), one request at a time through the local API, with the speed and whether each transcript matches the one recorded on the reference Mac (M5 Max) for that model, precision and engine.

`vella diagnose` never starts Vella and loads nothing: it times only models that are already loaded. `vella diagnose --load` first loads your dictation model (on demand, so it unloads after its Keep Hot time). `--json` prints the same data as JSON, the clip transcripts included. A dictation still goes first; if you are dictating, nothing is timed. The report contains no recordings, no transcripts of your speech and no file paths.

## Recordings, disk, recovery, and privacy

- Vella stores recordings and transcripts locally until you delete them, even after a successful paste. Choose **Open Vella Files** to find them.
- If disk space runs low, capture stops safely and saved audio is kept. Free space before continuing.
- Recording metadata is written first so an interrupted session stays recoverable. Integrity failures preserve files for recovery rather than silently discarding them. Streaming retries archive the previous event journal first.
- Vella does not upload recordings or transcripts. Apps you insert text into may sync or send that text according to their own settings.
- Clipboard managers and Universal Clipboard can still see text you copy or paste. Streaming live insertion avoids the clipboard per chunk; Dictation paste and recovery use the clipboard path described above.
- The command line and API listen on 127.0.0.1 only; files you send them are transcribed on this Mac and their temporary copies are removed afterwards.
- Model downloads (after you confirm one) are the only expected network transfer during normal use, plus the release check described above. The recognition helpers run in a sandbox that denies all network access; downloads are a separate helper, `VellaModelTool`.

## Updates

Vella checks GitHub for a newer stable release at launch and then once a day (a Mac that slept through the check tries soon after waking). The check is one HTTPS request to the public releases endpoint; Vella never sends audio or transcripts. Draft and prerelease versions are ignored, and an offline or failed check is silent and tries again in about an hour.

A newer release adds an orange **Update to X…** item under **Support the developer…**. It stays until you install that version or newer, also across restarts. Choosing it shows the version and the start of its release notes, with **Update Now** and **Later**. Nothing is downloaded until you choose Update Now. Then Vella:

1. Refuses, downloading nothing, while it is recording, transcribing, pasting, loading or downloading a model, calibrating, or transcribing a file for the API. Try again when it has finished.
2. Downloads `Vella-<version>-arm64.zip` and `SHA256SUMS` from the release and verifies them before anything changes: the exact checksum line for the zip, that the archive holds only `Vella.app` with its helpers and Metal library, its bundle identifier and version, its code signature, and that it is signed like the running app. A certificate-signed Vella accepts only code that satisfies its own designated requirement, so macOS privacy permissions carry over; an ad-hoc signed Vella accepts only an ad-hoc signed Vella, whose origin the checksum and HTTPS alone vouch for. macOS ties privacy permissions of ad-hoc signed apps to the exact build, so after such an update it may ask for Microphone and Accessibility again.
3. If you started a dictation meanwhile, waits until Vella is idle again (up to 15 minutes), then quits and hands the install to its installer tool.
4. The installer swaps the new app in with the previous one kept aside, starts it and waits until it is ready (the same rule as `scripts/install.sh`). Then the previous app is deleted. If the new version does not start, exits, keeps failing to load a model you keep loaded, or is still loading after 30 minutes, the previous version is put back and started, and it tells you why.

Settings, models and recordings in `~/Library/Application Support/Vella` are kept. Progress is logged to `update.log` there. `VELLA_UPDATE=0` turns the check off.

## Uninstall

1. Quit Vella.
2. Move `~/Applications/Vella.app` to the Trash.
3. Models, settings and recordings remain in `~/Library/Application Support/Vella`. Delete that folder separately only if you want them gone too.

## Further reading

- [README](../README.md) — what Vella does, the model table, install.
- [AGENTS.md](../AGENTS.md) — the install steps for a coding agent.
- [Agent skill](../Resources/SKILL.md) — what **Copy Skill for Your Agent** and `vella skill` provide.
- [Model integration guide](../Resources/AGENT_GUIDE.md) — what a new model needs before Vella can offer it.
- [License](../LICENSE) and [third-party notices](../THIRD_PARTY_NOTICES.md).
