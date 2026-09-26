---
name: transcribe
description: Transcribe audio files offline with Vella, the local speech-to-text app on this Mac. Use for recordings, voice memos, meetings, lectures, podcasts or video soundtracks (wav, mp3, m4a, flac, caf, aiff; up to 3 hours per file) when you need the text, subtitles (srt/vtt) or timed segments, without sending audio anywhere.
---

# Transcribe audio with Vella

Vella runs speech-recognition models on this Mac (Apple Silicon). Nothing leaves the machine. The same models the user dictates with transcribe your files; the user's own dictation always goes first, so a file may wait a moment while they speak.

## 1. Decide it fits

Use it when you have an audio file (or a video's audio track saved as audio) and need its words. It returns plain text, OpenAI-style JSON, timed segments (5–25 s each, cut at pauses), or SRT/VTT subtitles.

It does not translate, identify speakers, or give word-level timestamps. Very long files are fine up to 3 hours; split longer ones.

## 2. Call it

Shell, one file (prints the transcript; starts Vella if it is not running):

```sh
vella transcribe talk.m4a                      # plain text
vella transcribe talk.m4a --srt > talk.srt     # subtitles; --vtt, --json, --verbose-json (segments) also work
vella transcribe talk.m4a --model parakeet-v3  # a specific model; `vella models` lists the ones on this Mac
```

`vella status` prints one line (running, loaded models, API address); `vella url` prints the base URL.

Any language or SDK: Vella's local API is OpenAI-compatible, so code written for OpenAI's transcription endpoint works with only the base URL changed. The key is ignored but the SDKs require one:

```python
from openai import OpenAI
import subprocess
client = OpenAI(base_url=subprocess.check_output(["vella", "url"], text=True).strip(), api_key="local")
with open("talk.m4a", "rb") as f:
    text = client.audio.transcriptions.create(model="whisper-1", file=f, response_format="text")
```

`model="whisper-1"` means the user's current dictation model; any id from `GET /v1/models` picks another downloaded model (it loads on demand and unloads after the user's Keep Hot time). Vella never downloads a model through the API: if a model is missing, ask the user to get it in Vella → Models….

curl: `curl -s "$(vella url)/audio/transcriptions" -F file=@talk.m4a -F response_format=srt`. The port changes when Vella restarts, so read it each time (`vella url`, or `api_port` in `~/Library/Application Support/Vella/worker-status.json`).

## 3. Done when

You have the transcript and have read enough of it to confirm it matches the audio (right language, no long stretches missing). Tell the user which file you transcribed and with which model (`vella status` names the dictation model). Automatic transcripts misspell names and jargon: say so when those matter, and never present the text as a verbatim quote without checking it.

If Vella answers with an error, pass its one-line message to the user: it says what to do (for example "not downloaded; get it in Vella → Models…" or a memory refusal with the model's size).
