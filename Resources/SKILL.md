---
name: transcribe
description: Transcribe audio files offline with Vella, the local speech-to-text app on this Mac. Use for recordings, voice memos, meetings, lectures, podcasts or video soundtracks (wav, mp3, m4a, flac, caf, aiff; up to 3 hours per file) when you need the text, subtitles (srt/vtt) or timed segments, without sending audio anywhere.
---

# Transcribe audio with Vella

Vella runs speech-recognition models on this Mac (Apple Silicon); nothing leaves the machine. The models the user dictates with also transcribe your files. The user's own dictation always goes first, so a file may wait a moment while they speak.

## When to use

Fits when you have an audio file (or a video's audio track saved as audio) and need its words: plain text, OpenAI-style JSON, timed segments (up to about 25 s each, cut at pauses), or SRT/VTT subtitles.

Use another tool to translate, to identify speakers or for word-level timestamps. Split files longer than 3 hours.

## Install

`vella status` prints one line when Vella is installed. If `vella` is missing, try `~/.local/bin/vella`; if that is missing too, ask the user before installing: `curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash` (Apple Silicon, macOS 14 or newer; it ends with `ready: …`). A fresh install has no model: the user gets one in Vella → Models….

## Results

`vella transcribe` prints the transcript on stdout and nothing else; `--json`, `--verbose-json`, `--srt` and `--vtt` print that format instead. `vella status` and `vella url` print one line, `vella models` one line per model. An error is one line on stderr, `error: …`, that says what to do (for example "not downloaded; get it in Vella → Models…", or a memory refusal with the model's size), and the exit code is 1. Pass that line to the user. Commands start Vella if it is not running, except `vella diagnose`.

## Commands

```sh
vella transcribe talk.m4a                      # the transcript as plain text
vella transcribe talk.m4a --srt > talk.srt     # subtitles; --vtt, --json, --verbose-json (segments) also work
vella transcribe talk.m4a --model parakeet-v3  # a specific model
vella transcribe talk.m4a --language pl        # a language hint
vella models                                   # parakeet-v3-ultra  Parakeet v3 Ultra · BF16 · loaded · current dictation model   (one line per model on this Mac)
vella status                                   # Vella 1.0.0 running (pid 29335), parakeet-v3-ultra BF16 loaded · dictation model Parakeet v3 Ultra (BF16) · API http://127.0.0.1:63080/v1
vella url                                      # http://127.0.0.1:63080/v1
vella diagnose                                 # a bug report for the user; its last line is a prefilled GitHub issue link
```

## Done when

You have the transcript and have read enough of it to confirm it matches the audio (right language, no long stretches missing). Tell the user which file you transcribed and which model you asked for (the `--model` id, or their current dictation model). Vella picks the model again for each segment, so if the user loads or selects another model while a long file runs, the later part uses it; `vella status` afterwards names only the model selected now. Automatic transcripts misspell names and jargon: say so when those matter, and never present the text as a verbatim quote without checking it.

## API

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

`model="whisper-1"` means the user's current dictation model; any id from `GET /v1/models` picks another downloaded model (it loads on demand and unloads after the user's Keep Hot time). `response_format` is `text`, `json` (`{"text": "…", "usage": …}`), `verbose_json` (adds `segments` with `start`, `end`, `text`), `srt` or `vtt`.

## Limits

- No translation, no speaker labels, no word-level timestamps; files up to 3 hours.
- Vella never downloads a model through the API or the CLI. If a model is missing, ask the user to get it in Vella → Models….
- The user's dictation takes priority; a file waits while they speak.
- If transcripts look broken or transcription is far slower than expected, run `vella diagnose` and give the user its report and the bug-report link on its last line; they decide whether to file it. It never starts Vella and loads nothing unless you pass `--load`.
