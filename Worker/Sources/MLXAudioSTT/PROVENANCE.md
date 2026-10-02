# Provenance

`MLXAudioSTT` (and `MLXAudioCore`) started as a copy of mlx-audio-swift at
`01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (https://github.com/Blaizzy/mlx-audio-swift, MIT, `Worker/LICENSE-mlx-audio-swift`).
Vella keeps the model families it ships and the code they need:

| Folder | Upstream | Used for |
|---|---|---|
| `Parakeet/` | Parakeet (TDT only) | Parakeet v3 and v3 Ultra (Dictation) |
| `Qwen3ASR/` | Qwen3 ASR | Qwen3 ASR 1.7B and 0.6B (Dictation) |
| `Whisper/` | Whisper | Whisper large-v3 and large-v3 turbo (Dictation) |
| `NemotronASR/` | Nemotron ASR | Nemotron 3.5 streaming (Streaming) |
| `Nemo/` | shared NeMo layers | RNN-T layers, decoding, alignment of Parakeet and Nemotron |
| `Generation.swift`, `STTOutput.swift` | generation and output types | the dictation worker's model interface |

What Vella changed:

- **Local loading only.** Models load from a directory the worker admitted (`fromDirectory` / `fromModelDirectory`); the
  Hub loaders and Whisper's tokenizer download are gone, and the worker runs in a sandbox that denies all networking.
- **Optimized paths**, each enabled only after the load-time self-test (`FastPathGate`) passed on this Mac, with the
  stock path as the reference and the runtime fallback: Parakeet's fused encoder, 32-step TDT decoder and small-M NAX
  GEMMs (`FastParakeet*`, `SmallMGEMM`); Qwen3 ASR's pipelined decode and F32 audio tower; Whisper's pipelined decoder and
  fused decode step (`WhisperFusedDecode`); Nemotron's cache-aware streaming session and fused conformer layer
  (`VellaNemotron*`).
- **Precisions derived at load** from an installed float checkpoint (`DerivedPrecision`, `CheckpointQuantization`).
- **Removed** what the workers never call: streaming generation (`generateStream`), Nemotron's offline decode and
  upstream stream session, the SentencePiece tokenizer, batch and hybrid Parakeet decoders, the Parakeet variants
  outside the catalog (TDT-CTC, CTC, RNN-T without TDT), and unused DSP helpers.

The Parakeet frontend follows mlx-audio 0.5.1's MLX filterbank construction (`Worker/LICENSE-mlx-audio-python`);
Whisper's decoding settings follow mlx-whisper (`Worker/LICENSE-mlx-whisper`).
