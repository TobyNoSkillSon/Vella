# VellaWorker

Private offline Dictation helper. This separate SwiftPM package does not change the root app package or its CLT-only build. Build the helper with full Xcode and the Metal Toolchain:

```sh
xcrun swift build --package-path Worker -c release
```

The executable and the generated MLX resource bundle must travel together. No Python is used by this package's build or runtime. `QA/parity.py` is intentionally a developer-only comparison against the existing Python reference and frozen Python scorers, not a shipped component.

## Dependencies and offline boundary

MLX: `901941965d82e4a216d4d117231d847d194c563d`.
Vendored mlx-audio-swift: `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT; `LICENSE-mlx-audio-swift`). Source origin: https://github.com/Blaizzy/mlx-audio-swift . Vendored: the five Dictation model directories, shared NeMo layers, STT generation/output types, audio/DSP/SentencePiece utilities. Models use stock MLX operations with the documented Parakeet parity corrections below; no custom kernels or kernel optimisations.

Removed Hub/repository loaders and Whisper's automatic tokenizer download fallback. Models use directory-only entry points. Qwen's stock tokenizer synthesis runs in a private temporary directory rather than writing into installed weights. Granite's local half of its former Hub loader is exposed directly. The pinned LM common and tokenizer packages contain networking utilities transitively, but no Hub loaders are called; the executable additionally installs a fail-closed OS sandbox denying all networking before MLX/model loading. Qualification runs also wrap the executable in `sandbox-exec`.

Model admission mirrors `calibration_worker.validate_local`; errors deliberately disclose no model exception or transcript. One model is held; switching drops it and clears MLX allocations before loading another. EOF releases and exits; the app remains responsible for idle retirement and verified process exit. Cache limit is 64 MiB. SIGALRM terminates native work after 120 seconds. Input lines are bounded at 16 KiB. Audio is a bounded local PCM16 mono 16 kHz snapshot, at most 30 seconds / 2 MiB.

## Qualification status

See the task-local `vn-worker/STATUS.md` and report. Compilation alone is not inference parity. All five architectures have loader dispatch; only actually exercised model runs can establish support. Exact transcript identity and non-regression in both WER and CER are release gates.

Stock Parakeet serial TDT decoding evaluates decisions, hidden and cell each step, then reads a two-element decision tensor to the host (`eval` followed by `asArray(Int32.self)`). It is not the Python 32-step batched custom decoder. RNNT likewise evaluates joint logits and extracts argmax each step. No kernel port has begun.

CPU-only checks (no models or GPU work): `Worker/QA/check.sh`. On the current host, use `DEVELOPER_DIR=/Library/Developer/CommandLineTools Worker/QA/check.sh` because the selected Xcode 27 compiler emits a Swift-runtime symbol absent on macOS 26.6. A CLT `--build-system native` compile checks the Swift/C++ sources, but does **not** produce the required Metal library and is not a qualified runnable helper build.

### Xcode 27 / macOS 26.6 compatibility build

`Worker/build-split.sh` compiles Swift/C++ with the existing CLT Swift 6.3.3, then compiles the pinned MLX package's ten prepared Metal sources using Xcode's installed Metal compiler. It creates the required `mlx-swift_Cmlx.bundle` beside the executable and records compiler versions, deployment target and artifact hashes in `Worker/.build/split-build-provenance.txt`. No installation or Python is involved. Explicit macOS 14 deployment alone does not fix Xcode Swift 6.4's `_swift_initBorrow` launch failure on this host.

### Parakeet parity corrections

The stock Swift models required three compatibility changes to reproduce the Python worker rather than silently change its arithmetic: BF16 waveform input; preserve checkpoint floating dtypes in the generic local loader (Q4 contains both F16 and F32 tensors); initialize predictor state from encoder output dtype. Parakeet's frontend now follows mlx-audio 0.5.1's standard MLX filterbank construction, matrix orientation/reduction axes and Double-generated Hann window. This is ordinary MLX DSP, not custom Metal or a fast-path kernel. Python source attribution is in `LICENSE-mlx-audio-python`; the other four architectures retain their stock numerical implementations.

The protocol parity suite splits its sole >30-second clip (`7021-79730-0003`, 32.88 seconds) into 30 + 2.88 seconds for both workers and joins their text, because both real workers reject an intact request longer than 30 seconds. Do not label these results as published intact-clip direct-generation benchmarks.

Current qualification is incomplete: the Q4 protocol corpus matches all 144 clips, but Ultra BF16 has two residual differences and repeated in-process model switching retains increasing active allocations. SenseVoice weights were unavailable locally. Do not ship this checkpoint; verified worker exit remains the hard memory-release boundary.
