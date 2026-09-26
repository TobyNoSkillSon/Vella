# VellaWorker

Private offline recognition helpers (`VellaWorker` for Dictation, `VellaStreamingWorker` for Streaming). This separate SwiftPM package does not change the root app package. `scripts/build.sh` builds it with the Command Line Tools Swift and compiles the pinned MLX shaders with Xcode's Metal compiler (`Worker/build-split.sh`), then smoke-tests both helpers before bundling them.

The executable and the generated MLX resource bundle must travel together. No Python is used by this package's build or runtime.

## Dependencies and offline boundary

MLX: `901941965d82e4a216d4d117231d847d194c563d`.
Vendored mlx-audio-swift: `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT; `LICENSE-mlx-audio-swift`). Source origin: https://github.com/Blaizzy/mlx-audio-swift . Vendored: the five Dictation model directories, shared NeMo layers, STT generation/output types, audio/DSP/SentencePiece utilities. Optimized components (custom Metal kernels) run only after a load-time self-test against the stock MLX path in a child process; otherwise the stock path runs.

Removed Hub/repository loaders and Whisper's automatic tokenizer download fallback. Models use directory-only entry points. Qwen's stock tokenizer synthesis runs in a private temporary directory rather than writing into installed weights. Granite's local half of its former Hub loader is exposed directly. The pinned LM common and tokenizer packages contain networking utilities transitively, but no Hub loaders are called; the executable additionally installs a fail-closed OS sandbox denying all networking before MLX/model loading.

Model admission validates the local folder before loading; errors deliberately disclose no model exception or transcript. One model is held; switching drops it and clears MLX allocations before loading another. EOF releases and exits; the app remains responsible for idle retirement and verified process exit. Cache limit is 64 MiB. SIGALRM terminates native work after 120 seconds. Input lines are bounded at 16 KiB. Audio is a bounded local PCM16 mono 16 kHz snapshot, at most 30 seconds / 2 MiB.

## Build

`Worker/build-split.sh` compiles Swift/C++ with the existing CLT Swift 6.3.3, then compiles the pinned MLX package's ten prepared Metal sources using Xcode's installed Metal compiler. It creates the required `mlx-swift_Cmlx.bundle` beside the executable and records compiler versions, deployment target and artifact hashes in `Worker/.build/split-build-provenance.txt`. No installation or Python is involved. Explicit macOS 14 deployment alone does not fix Xcode Swift 6.4's `_swift_initBorrow` launch failure on this host.

## Attribution

Parakeet's frontend follows mlx-audio 0.5.1's MLX filterbank construction; that Python source's attribution is in `LICENSE-mlx-audio-python`. Whisper decoding settings follow mlx-whisper (`LICENSE-mlx-whisper`).
