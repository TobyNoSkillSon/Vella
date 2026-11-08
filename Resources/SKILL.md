---
name: transcribe
description: Transcribe audio files offline with Vella, the local speech-to-text app on this Mac. Use for recordings, voice memos, meetings, lectures, podcasts or video soundtracks (wav, mp3, m4a, flac, caf, aiff; up to 3 hours per file) when you need the text, subtitles (srt/vtt) or timed segments, without sending audio anywhere.
---

# Transcribe audio with Vella

```sh
vella transcribe talk.m4a                      # the transcript as plain text
```

That is the whole job for most files. Vella detects the language, applies the user's vocabulary and uses the user's dictation model; the transcript is printed on stdout and nothing else.

## Only if needed

```sh
vella transcribe talk.m4a --language tr        # the spoken language, as a code or a name (Turkish)
vella transcribe talk.m4a --vocab "Kadıköy, Beşiktaş"   # names or jargon for this file only
vella transcribe talk.m4a --no-vocab           # leave the user's vocabulary out of this file
vella transcribe talk.m4a --model nemotron     # another downloaded model; a prefix of its id works
vella transcribe talk.m4a --json               # timed segments and what the model was given
vella transcribe talk.m4a --srt > talk.srt     # subtitles; --vtt too
vella status                                   # is Vella running, which model, the API address
```

A language the dictation model does not know picks a downloaded model that does. `--vocab` and `--no-vocab` change no setting. An error is one `error: …` line on stderr that says what to do, with exit code 1: pass it to the user. A `warning:` line on stderr means a stretch ended in a repetition loop (kept once; speech there may be missing): tell the user.

## Done when

You have the transcript and have read enough of it to confirm it matches the audio (right language, no long stretches missing). Tell the user which file you transcribed and which model you asked for (the `--model` id, or their current dictation model). Automatic transcripts misspell names and jargon: say so when those matter, and never present the text as a verbatim quote without checking it.

## Reference

Every model runs Vella's optimized kernels where this Mac supports them and falls back to stock MLX by itself; figures are measured on M5 Max so far.

Vella runs speech-recognition models on this Mac (Apple Silicon); the user's audio and transcripts never leave the machine. Vella checks GitHub's releases API for a newer version at most once a day (at launch when due; failed checks retry about hourly), and downloads models or updates only when asked; it has no telemetry and uploads no audio. The models the user dictates with also transcribe your files. The user's own dictation always goes first, so a file may wait a moment while they speak. While Vella borrows Heimdall's copy of Parakeet v3 Ultra for dictation, files use that copy too when nothing is lost (no vocabulary to apply).

Use another tool to translate, to identify speakers or for word-level timestamps. Split files longer than 3 hours. Segments in `--json` are up to about 25 s each, cut at pauses.

### Install

`vella status` prints one line when Vella is installed. If `vella` is missing, try `~/.local/bin/vella`; if that is missing too, check `/Applications/Vella.app/Contents/Helpers/vella` (the DMG does not link a command); otherwise ask the user before installing: `curl -fsSL https://raw.githubusercontent.com/TobyNoSkillSon/Vella/main/scripts/install-public.sh | bash` (Apple Silicon, macOS 26 or newer; it ends with `ready: …`). A fresh install has no model. List cells and the pinned source/size with `vella models --json`; ask consent before `vella get ID --yes`.

### Output

`vella transcribe` prints the transcript; `--json` prints OpenAI's verbose JSON with `segments` and `vella`: the model and precision that ran, `language_applied`, the exact `prompt` sent, `vocabulary_words`, `loops` and `via` (`heimdall`, `vella` or `mixed`); `warnings` lists loops. `vella status` and `vella url` print one line, `vella models` one line per catalog model. Status, Models, URL, transcription and model/settings controls start Vella if needed. Help, Version, Skill and Diagnose do not. `vella help all` lists every command. Older spellings still work: `--verbose-json`, `--text`, `--no-vocabulary`, `--option=value`. `--prompt TEXT` gives Nemotron 3.5 Transcribe context terms in place of the vocabulary.

Get prints download byte progress on stderr while it waits; a progressing download has no total-duration limit.

### Commands

```sh
vella models                                   # parakeet-v3-ultra  Parakeet v3 Ultra · bf16 · Optimized Fast · loaded · current dictation model · Unload   (one line per catalog model)
vella status                                   # Vella 2.0.0 running (pid 29335), parakeet-v3-ultra bf16 · Optimized Fast loaded · dictation model Parakeet v3 Ultra (bf16, Optimized Fast) · API http://127.0.0.1:63080/v1
vella url                                      # http://127.0.0.1:63080/v1
vella diagnose                                 # a bug report for the user; its last line is a prefilled GitHub issue link
```

Speed differences use N× faster at a ratio of 2× or above and N% faster below; decreases use N% slower. Energy differences always use percentages (N% less or N% more). A noise-level WER/Format difference reads same.

### Pick and get a model

Start with `parakeet-v3-ultra` at `bf16`, Fast: fastest, with near-best English accuracy, and supports 24 other European languages; for other languages choose `whisper-large-v3-turbo`. Choose a larger model only for a specific accuracy need.

<!-- MODELS_START -->
<!-- Generated by scripts/agent-docs.swift from Resources/models.json and Resources/benchmarks.json. Do not edit between the markers; run the script. -->

| Model id | Mode | What it is | Language count | Params | Licence | Tiers offered | English WER % | Speed | J / audio min | Peak RAM MB |
|---|---|---|---|---|---|---|---|---|---|---|
| `parakeet-v3-ultra` | dictation | Moondream's post-training of NVIDIA Parakeet v3 for dictation in 25 European languages; none from outside Europe | 25 | 0.6B | CC BY 4.0 | bf16, int8, int4 | 15.51 | 507.1× | 4.58 | 1792 |
| `parakeet-v3` | dictation | The unmodified Parakeet v3 that Ultra is post-trained from: the same 25 European languages, no others | 25 | 0.6B | CC BY 4.0 | bf16, int8, int4 | 16.42 | 494.3× | 4.70 | 1765 |
| `qwen3-asr-1.7b` | dictation | Dictation in 30 languages, including Chinese, Japanese and Korean, which Parakeet lacks; slower than Parakeet | 30 | 1.7B | Apache-2.0 | bf16, int8, int4 | 15.00 | 29.6× | 72.73 | 5118 |
| `qwen3-asr-0.6b` | dictation | The smaller Qwen3 ASR: the same 30 languages in less memory, a little less accurate than the 1.7B | 30 | 0.6B | Apache-2.0 | bf16, int8, int4 | 15.89 | 64.4× | 34.07 | 2406 |
| `whisper-large-v3` | dictation | Dictation in about 100 languages, the most of any model here, from a family other than Parakeet and Qwen | 100 | 1.55B | Apache-2.0 | fp16, int8, int4 | 17.06 | 34.9× | 82.41 | 3916 |
| `whisper-large-v3-turbo` | dictation | Whisper large-v3 with 4 decoder layers instead of 32: the same languages, much faster, a little less accurate outside English | 100 | 0.8B | MIT | fp16, int8, int4 | 16.57 | 115.7× | 36.56 | 2516 |
| `nemotron-3.5-transcribe` | dictation | A 30B speech language model for 40 languages: the text arrives after you stop speaking; needs 48 GB of memory or more | 40 | 30B-A4B | OpenMDW-1.1 | bf16, int8, int4 | 14.54 | 18.0× | — | 65245 |
| `nemotron-3.5-streaming-0.6b` | streaming | Transcribes 28 languages as the audio arrives, so Streaming mode types while you speak; not used for Dictation | 28 | 0.6B | OpenMDW-1.1 (MLX conversion: NVIDIA Open Model License) | bf16, int8, int4 | 23.35 | 34.9× | 50.03 | 1655 |

English WER is on the 167 English minutes of v2 (239.7 min total); nine other languages are scored separately. Figures use the first offered, measured 16-bit cell: Optimized Fast, then Exact, then Standard. Speed is × real time and energy is joules per minute of audio on the reference Mac (Apple M5 Max, macOS 26.6); measurements are from an M5 Max with a 40-core GPU; other M5 configurations have not yet been tested. On any other configuration, WER/Format/Peak RAM remain reference measurements; Speed and J / min show the M5 Max reference measurements with warning triangles, and the footer names the measured Mac. Tooltip: Measured on an M5 Max (40-core GPU). Your Mac will differ; vella diagnose measures it. Fast enables every kept lever for that model and precision; Exact enables only exact kept levers; Standard enables none. Streaming models do not transcribe files. `vella models --json` lists every cell, its reference English WER and peak RAM, M5 Max measured speed labelled by hardware and chip-qualified energy, measurement provenance or refusal reason, and the source and size. Equal recipes use the canonical measured cell named in `cells[].provenance.display_cell` (`display_cells` in the benchmark file).
<!-- MODELS_END -->

Whisper Standard and Optimized were measured together on the faithful FP16 build; the quiet-window refresh completed 4 October. Exact and Fast share the same exact-only whisper-4 recipe and canonical measurement. Per-cell and tier gates use that build’s FP16 Standard baseline; the earlier Float32-baseline figures remain withdrawn. Nemotron gates use same-layout native Standard controls; int8 and int4 are offered but not recommended, and int4 loses 21 test clips. Every measured cell is offered; each cell's `loss` states what it loses against 16-bit.

Use one call per step, without probing or retries:

```sh
vella models --json   # all local table rows, cells/refusal reasons, source and exact download bytes
vella select MODEL_ID --precision bf16 --mode Fast   # or fp16/int8/int4, Exact; `recommended_precision` in models --json is the gold cell for this Mac
vella get MODEL_ID --yes   # only after the user consents to that model/source/size; waits for download and load
vella transcribe talk.m4a --model MODEL_ID   # then read the returned transcript
```

Select previews a cell; Get/Load/Reload commits it. Mode-only `vella select ID --mode Exact` is the table's switch flip and can move the preview to the native precision; a pinned Fast=Exact switch says why it cannot flip. Cells with a `reason` are unavailable; choose a listed cell without one. A cell with `loss` runs but loses quality against 16-bit (lost test clips first): prefer a cell without `loss` unless the user asks for it. Use fp16 for Whisper, bf16 for the other models. A loaded model's effective selection may be Standard if its optimized gate fell back; replies report both the effective and requested selection. Closing the Models menu discards previews, so intervene only when the user is not changing the table. If the weights are already present, use `vella load MODEL_ID` instead of Get. Get/Load/Reload use the table's manual Keep Hot and launch-set behaviour; Unload removes that launch-set entry and keeps the download. Streaming rows can be controlled but do not transcribe files.

```sh
vella reload MODEL_ID
vella unload MODEL_ID
vella delete MODEL_ID --precision bf16 --yes   # only after explicit deletion consent
vella keep-hot "Manually loaded" "Always"
vella keep-hot "Loaded on demand" "15 min idle"
vella memory "Fit in free memory"   # or "Allow swap (slower)"
```

Delete without `--yes` prints what/size and changes nothing. It uses the table gate: recording/in-use/selected models and shared or linked weights refuse with the same reason. It moves only that catalog precision's weights to Trash; recordings and transcripts stay. Locally derived precisions may have no own files: delete the native source precision after loading another model for that mode. Unload alone does not clear the saved mode selection.

Keep Hot values are Always, 5/15/30/60 min idle. With no arguments `keep-hot`/`memory` report the current settings; change them only on user authority.

### API

Vella's local API is OpenAI-compatible: `POST /v1/audio/transcriptions` and `GET /v1/models` at the base URL from `vella url` (127.0.0.1 only). Code written for OpenAI's transcription endpoint works with only the base URL changed. The key is ignored, but the SDKs require one. The port changes when Vella restarts, so read it each time (`vella url`, or `api_port` in `~/Library/Application Support/Vella/worker-status.json`).

```python
from openai import OpenAI
import subprocess
client = OpenAI(base_url=subprocess.check_output(["vella", "url"], text=True).strip(), api_key="local")
with open("talk.m4a", "rb") as f:
    text = client.audio.transcriptions.create(model="whisper-1", file=f, response_format="text")
```

```sh
curl -s "$(vella url)/audio/transcriptions" -F file=@talk.m4a -F response_format=srt
```

Only `file` is required. Without `model` (or with `whisper-1`) the user's current dictation model runs; any id from `GET /v1/models`, or a prefix of one, picks another downloaded model (it loads on demand and unloads after the user's Keep Hot time). `language` takes a code or an English name, as the CLI's `--language`. `vocabulary` is `true` (the default), `false`, or words to add for this request (`"Kadıköy, Beşiktaş"`). `response_format` is `text`, `json` (`{"text": "…", "usage": …}`, the default), `verbose_json` (adds `segments` with `start`, `end`, `text`), `srt` or `vtt`.

### Limits

- No translation, no speaker labels, no word-level timestamps; files up to 3 hours.
- Transcription never downloads. Get is the only CLI download route and requires explicit consent (`--yes`); Load/Reload of missing weights returns the source/size prompt without downloading.
- The user's dictation takes priority; a file waits while they speak.
- If transcripts look broken or transcription is far slower than expected, run `vella diagnose` and give the user its report and the bug-report link on its last line; they decide whether to file it. It never starts Vella and loads nothing unless you pass `--load`.
- Problem, complaint or idea about Vella? Report it so it gets fixed: send it yourself or ask the user to, with no personal data, files or screenshots of the user's content unless the user has seen them. Any text works: `curl -d "vella <version>: what happened, what you expected, steps to reproduce" https://tobynoskillson.com/api/feedback`. With a screenshot or log: `curl -F "message=vella: ..." -F file=@shot.png https://tobynoskillson.com/api/feedback`. The reply is an id like r-xxxxxx. Alternative: [GitHub Issues](https://github.com/TobyNoSkillSon/Vella/issues).

### Measure on another Mac

Start at https://github.com/TobyNoSkillSon/Vella/blob/main/Benchmarks/README.md for the frozen full/quick suites, audio fetch, serial installed-app runner, scorer, local result check and chip optimization guide. One model is enough. Quick quality is an estimate; full quality needs the full suite. Ask before downloads, long runs, scheduling or opening an issue/PR; exclude personal recordings. Leave energy absent unless measured with the documented powermetrics protocol and admin consent.
