# Changelog

## 2.0.0 ({{release_date}})

### Added

- **Models controls for agents.** `vella models --json` lists all table rows and cells; Select, Get (explicit `--yes` consent), Load, Reload, Unload, Delete (explicit precision and `--yes`), Keep Hot and Memory use the table's controller and runtime. Authenticated local API routes expose the same controls; file transcription itself still never downloads.
- **Optional disk image.** `scripts/package-dmg.sh` makes a local `Vella-2.0.0.dmg` from the verified release ZIP, keeps the app's existing signature and adds its checksum. The primary installer still uses the ZIP.

### Changed

- **Licence.** Vella 2.0 is GNU AGPL-3.0-only. Published 0.x releases remain Apache-2.0; their licences are not changed retroactively. Third-party code and model weights retain their own licences.
- **Chip coverage.** Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far. The CLI help and agent guides state that boundary explicitly.
- **Installation.** The release installer remains the primary route: checksum and signature verification, quarantine removal and automatic launch. The standalone installer now checks macOS 26, matching the shipped app. `scripts/install.sh --dry-run` now forwards verification-only mode correctly.
- **Updating can change the precision a model runs at.** If your settings record a precision the Models table no longer offers (Parakeet v3 8-bit or 4-bit, Qwen3 ASR 1.7B 8-bit or 4-bit, a 4-bit Qwen3 ASR 0.6B, Whisper or Nemotron) or a cell that has no measurement, dictation, live transcription, `vella` and the API now run the cell the table shows for that model: the same tier's Optimized cell, else 16-bit, which can use more memory. Nothing is downloaded for this; if none of the offered precisions is on this Mac, the older download keeps working as before. A model already loaded at such a precision keeps it until it unloads. Pick another cell in **Models…** to change it.
- **The dictation helper keeps up to 64 MB of reusable GPU buffers between requests** instead of freeing them after every request, so dictation is slightly faster (about 4 % on Parakeet v3 Ultra BF16). It never holds more than 64 MB while idle, frees them after a failed request, and releases them on unload or when macOS reports memory pressure. `VELLA_DICTATION_KEEP_CACHE=0` restores the old behaviour.
- **Smaller app and download.** Dictation and live-transcription helpers are now one program, and shipped programs carry no debug symbols. Both helper processes appear as **VellaWorker** in Activity Monitor, `top` and crash reports (signing identifier `VellaWorker`); the streaming one is still started as `VellaStreamingWorker`. Use a PID rather than a process name for diagnostics. Release packages include a separate, checksummed `Vella-VERSION-arm64-symbols.zip` with UUID-matched dSYMs for crash symbolication; installers download only the app. Plain source builds retain no extra symbol directories.
- **Only catalog models load.** Vella loads the models in its catalog (downloaded or converted through the Models table); a model folder chosen some other way is no longer accepted. At launch, a dictation or streaming selection that points outside the catalog is cleared (and noted in the log).
- **Models table.** Every model shows all six Precision cells, named by the format that runs (`bf16`/`fp16`, `int8`, `int4`), on an Optimized row (a bolt) above a Standard row (the MLX logo); a cell the model cannot run is greyed in place with the reason in its tooltip. The Fast/Exact switch is as tall as both rows and sets the Optimized row. **Memory** is now **Peak RAM**. The Capabilities column is gone (each model's languages are in its name's tooltip), and a thick line divides the Dictation and Streaming groups. The Models menu takes the table's exact width, so the row buttons are no longer cut off at its right edge. Until the build that ships is measured, the figure columns show `—`.
- The optimized path's load self-test checks only the kernel class Vella uses, so a load qualifies sooner (about 0.6 s instead of 0.7 s on an M5 Max). Keys, verdicts and engine labels are unchanged.
- Removed development switches: `VELLA_UPDATE_CA_CERT`, `VELLA_QWEN_ENC_BF16`, `VELLA_QWEN_PREFILL_HEAD`, `VELLA_QWEN_HOST_LENGTHS`, `VELLA_QWEN_REFERENCE_LENGTHS`, `VELLA_WHISPER_ENC_F16`, `VELLA_WHISPER_FUSED`, `VELLA_PARAKEET_FP32_FRONTEND`, `VELLA_NEMO_GEMV_R`, `VELLA_NEMO_GEMV_S`, `VELLA_RENDER_SWITCH_WORDS`. Parakeet loads TDT models only. `VellaModelTool` is a stub that prints a notice (kept for 1.0.x updaters).
- Code reorganised by feature, with one model interface in the recognition helpers, a shared wire package (`Packages/VellaWire`), Swift 6 language mode for the MLX-free libraries and tools, and SwiftLint and swift-format checks (`scripts/lint.sh`).

### Fixed

- **Short or silent endings no longer become separate requests.** A dictation or file whose last segment had under 2 s of new audio, or no audio above the silence level, sent that piece to the model on its own: Whisper answered such pieces with "Thank you." and similar phrases, and Parakeet dropped the opening sentences of a clip cut 0.1 s before its end. That piece is now transcribed together with the segment before it. Saved recordings are written and cut exactly as before.
- **Whisper models get longer segments.** Whisper was trained on 30 s windows; it now cuts at a pause only after 20 s (other models: 5 s), so it sees whole sentences and makes fewer errors at cuts.

## 1.0.0 (2026-09-27)

### Added

- **Prebuilt install.** `scripts/install.sh` downloads the release zip with curl, verifies its SHA-256, contents, version and code signature before touching anything, swaps the app in place and waits until it is ready (`ready: …`). `scripts/install-release.sh <version> --dry-run` verifies without installing. No Xcode or Python needed; `VELLA_BUILD=source` builds the checkout instead.
- **Models table.** One row per model with a precision control (`4b`, `8b`, `BF16`, `FP16`, `FP32` as the weights allow), Dictation and Streaming sections, and measured WER, formatting error, speed, energy (J per minute of audio) and memory. The recommended precision is green; other precisions show their difference from it. **Reload** applies a new precision to a loaded model.
- **Keep Hot** per kind of load: manually loaded models stay loaded (default Always) and load again at launch; models loaded for a dictation unload after 15 idle minutes by default.
- **Memory**: *Fit in free memory* (default) unloads idle models or refuses a load with the numbers and remedies; *Allow swap (slower)* skips the check.
- **Engine label** `Optimized · <chip>` or `MLX` under a loaded model, backed by a self-test at load and a fallback that redoes a failed optimized transcription on the stock path.
- **First dictation without a model** keeps the recording and offers **Get <model> (<size>)**; the recording is transcribed once the model is ready.
- **In-app updates.** A newer release shows an orange **Update to X…** item under **Support the developer…**. **Update Now** downloads the release, verifies its SHA-256, contents, version and that it is signed like the running app, installs it when Vella is idle and restarts; if the new version does not become ready, the previous one is restored. It replaces the notice that only opened the release page.
- **Audio files, for you and your agents.** `vella transcribe <file>` (text, `--srt`, `--vtt`, `--json`) and an OpenAI-compatible local API (`POST /v1/audio/transcriptions`, `GET /v1/models`, `GET /status`) on 127.0.0.1, so the OpenAI SDKs work with only the base URL changed. Any audio macOS decodes, up to 3 hours; dictation always goes first; nothing is pasted or kept. The installer links `vella` into `~/.local/bin`; **Copy Skill for Your Agent** and `vella skill` provide the agent skill.
- **One-command install without git.** `curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash` now installs the prebuilt release with the same checks as `scripts/install.sh` (it built 0.8.8 from source with Python). `bash -s -- --dry-run` verifies without installing.
- **Benchmark site** at https://tobynoskillson.github.io/Vella/: every measured model and precision on the v2 benchmark, sortable, with the estimated cloud API rows.

### Changed

- **A fresh install downloads and loads nothing.** Earlier versions downloaded and selected Parakeet Q4 during installation.
- One helper process per loaded model; a crashed helper restarts up to three times (after 2, 4 and 6 s). Helpers exit when Vella quits or is force-quit, and helpers left behind by an earlier Vella are stopped at launch, matched by their executable file only.
- The installer keeps the previous app until the new one reports ready, and refuses while a model is loading as well as during dictation.
- Updates replace the whole app bundle, so files from older versions (including Python-era resources) never survive an update.

### Removed

- The Python source-build installer and runtime files. Benchmark corpora, raw results and developer test harnesses are no longer part of the repository.
