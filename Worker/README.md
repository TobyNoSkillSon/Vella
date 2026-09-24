# VellaWorker

Private offline Dictation helper. This separate SwiftPM package does not change the root app package or its CLT-only build. Build the helper with full Xcode and the Metal Toolchain:

```sh
xcrun swift build --package-path Worker -c release
```

The executable and the generated MLX resource bundle must travel together. No Python is used by this package's build or runtime. `QA/parity.py` is intentionally a developer-only comparison against the existing Python reference and frozen Python scorers, not a shipped component.

## Dependencies and offline boundary

MLX: `901941965d82e4a216d4d117231d847d194c563d`.
Vendored mlx-audio-swift: `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT; `LICENSE-mlx-audio-swift`). Source origin: https://github.com/Blaizzy/mlx-audio-swift . Vendored: the five Dictation model directories, shared NeMo layers, STT generation/output types, audio/DSP/SentencePiece utilities. Numerical model implementations remain stock; no custom kernels or kernel optimisations.

Removed Hub/repository loaders and Whisper's automatic tokenizer download fallback. Models use directory-only entry points. Qwen's stock tokenizer synthesis runs in a private temporary directory rather than writing into installed weights. Granite's local half of its former Hub loader is exposed directly. The pinned LM common and tokenizer packages contain networking utilities transitively, but no Hub loaders are called; the executable additionally installs a fail-closed OS sandbox denying all networking before MLX/model loading. Qualification runs also wrap the executable in `sandbox-exec`.

Model admission mirrors `calibration_worker.validate_local`; errors deliberately disclose no model exception or transcript. One model is held; switching drops it and clears MLX allocations before loading another. EOF releases and exits; the app remains responsible for idle retirement and verified process exit. Cache limit is 64 MiB. SIGALRM terminates native work after 120 seconds. Input lines are bounded at 16 KiB. Audio is a bounded local PCM16 mono 16 kHz snapshot, at most 30 seconds / 2 MiB.

## Qualification status

See the task-local `vn-worker/STATUS.md` and report. Compilation alone is not inference parity. All five architectures have loader dispatch; only actually exercised model runs can establish support. Exact transcript identity and non-regression in both WER and CER are release gates.

Stock Parakeet serial TDT decoding evaluates decisions, hidden and cell each step, then reads a two-element decision tensor to the host (`eval` followed by `asArray(Int32.self)`). It is not the Python 32-step batched custom decoder. RNNT likewise evaluates joint logits and extracts argmax each step. No kernel port has begun.

CPU-only checks (no models or GPU work): `Worker/QA/check.sh`. On the current host, use `DEVELOPER_DIR=/Library/Developer/CommandLineTools Worker/QA/check.sh` because the selected Xcode 27 compiler emits a Swift-runtime symbol absent on macOS 26.6. A CLT `--build-system native` compile checks the Swift/C++ sources, but does **not** produce the required Metal library and is not a qualified runnable helper build.
