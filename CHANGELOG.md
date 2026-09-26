# Changelog

## 1.0.0 (unreleased)

### Added

- **Prebuilt install.** `scripts/install.sh` downloads the release zip with curl, verifies its SHA-256, contents, version and code signature before touching anything, swaps the app in place and waits until it is ready (`ready: …`). `scripts/install-release.sh <version> --dry-run` verifies without installing. No Xcode or Python needed; `VELLA_BUILD=source` builds the checkout instead.
- **Models table.** One row per model with a precision control (`4b`, `8b`, `BF16`, `FP16`, `FP32` as the weights allow), Dictation and Streaming sections, and measured WER, formatting error, speed, energy (J per minute of audio) and memory. The recommended precision is green; other precisions show their difference from it. **Reload** applies a new precision to a loaded model.
- **Keep Hot** per kind of load: manually loaded models stay loaded (default Always) and load again at launch; models loaded for a dictation unload after 15 idle minutes by default.
- **Memory**: *Fit in free memory* (default) unloads idle models or refuses a load with the numbers and remedies; *Allow swap (slower)* skips the check.
- **Engine label** `Optimized · <chip>` or `MLX` under a loaded model, backed by a self-test at load and a fallback that redoes a failed optimized transcription on the stock path.
- **First dictation without a model** keeps the recording and offers **Get <model> (<size>)**; the recording is transcribed once the model is ready.
- **Audio files, for you and your agents.** `vella transcribe <file>` (text, `--srt`, `--vtt`, `--json`) and an OpenAI-compatible local API (`POST /v1/audio/transcriptions`, `GET /v1/models`, `GET /status`) on 127.0.0.1, so the OpenAI SDKs work with only the base URL changed. Any audio macOS decodes, up to 3 hours; dictation always goes first; nothing is pasted or kept. The installer links `vella` into `~/.local/bin`; **Copy Skill for Your Agent** and `vella skill` provide the agent skill.

### Changed

- **A fresh install downloads and loads nothing.** Earlier versions downloaded and selected Parakeet Q4 during installation.
- One helper process per loaded model; a crashed helper restarts up to three times (after 2, 4 and 6 s). Helpers exit when Vella quits or is force-quit, and helpers left behind by an earlier Vella are stopped at launch, matched by their executable file only.
- The installer keeps the previous app until the new one reports ready, and refuses while a model is loading as well as during dictation.
- Updates replace the whole app bundle, so files from older versions (including Python-era resources) never survive an update.

### Removed

- The Python source-build installer and runtime files. Benchmark corpora, raw results and developer test harnesses are no longer part of the repository.
