# Native Streaming helper

`VellaStreamingWorker` is the private, one-session JSONL executable. No Python,
network model resolution, or runtime tokenizer downloads. It accepts the same
`start`, `audio`, `finish` requests as `Resources/streaming_worker.py`; stdout is
ASCII JSON only. The process exits on Finish, malformed input, native failure,
EOF, SIGTERM, or 120 seconds without request completion. The OS denies networking.

The pure Swift Session retains at most 319 pending transport samples, fifteen
20-ms pre-roll blocks, and bounded text delivery. It gates using Double RMS over
Float32 PCM, preserving finite resampler overshoot up to amplitude 16. Endpoints
flush before reset. Greedy text drains at complete spaces near 2048 UTF-8 bytes;
8192-byte delivery/boundary failures terminate rather than dropping a suffix.

## Model state

Both families are vendored from mlx-audio-swift
`01dec7c9bdce3088a6b6b7ab9f2e403458195efb`, MIT (see
`LICENSE-mlx-audio-swift`). Upstream source:
https://github.com/Blaizzy/mlx-audio-swift

- **Nemotron:** `VellaNemotronSession` uses a hop-aligned retained PCM tail,
  pending mel frames, `(56,3)` cache-aware conformer chunks, persistent RNNT token
  and LSTM state. No utterance waveform/token list is retained. Production keeps
  Float32 mel input, as Python does; upstream's blanket BF16 mel cast is bypassed.
  Relative-position tables use Python's MLX Float32 operation sequence rather
  than upstream CPU Float trigonometry; this fixes the observed BF16 word delay.
- **Voxtral:** `VellaVoxtralSession` implements 1280-frame feed buffering, 64-token
  step yields, 480-ms delay, close plus at most 32 extra steps. It retains causal
  convolution, projection tail, absolute encoder and decoder positions and sliding
  KV. Unlike upstream's convenience session it never resets the encoder at
  750-frame block boundaries and never caps the whole utterance at 4096 tokens.
  UTF-8 incomplete bytes are held until stable; consumed adapter rows and emitted
  text are retired after each step. Multiframe encoder attention keeps the previous
  749 rows before appending the chunk, matching Python's rotating-cache context.

The upstream convenience sessions remain available in the model library but are
**not** used by the helper. Repository/Hub loaders and optional VAD imports/entry
points were removed. `fromDirectory` is the only model loading route used.

## Developer checks

Current verification is limited to unit/protocol checks and at most 3–5 short
public clips per model. `QA/streaming_smoke.py` enforces that limit and records
only protocol/transcript correctness, not scores or timings. Corpus benchmark
tools below are retained for later explicitly authorized manual use; they are
not part of builds or automatic verification.

CPU-only checks compile `StreamingSession.swift` with
`QA/StreamingChecks.swift`. `QA/streaming_protocol_parity.py` compares the real
Python and Swift Sessions with identical fake native models and random transport
framing; compile its fixture from `QA/StreamingProtocolFixture.swift`.
`QA/StreamingWatchdogChecks.swift` tests structured SIGTERM while main is blocked.

`QA/streaming_parity.py` exercises both **production executables** with identical
100-ms corpus packets, process exit per clip, and optional real-time pacing /
silence gaps. `QA/streaming_batch_parity.py` retains weights between fresh Sessions
like the repository's streaming benchmark; `VellaStreamingProbe` links symlinks
to the same production Session/adapters and is a **QA-only product**, not shipped.
All model harnesses check the user's idle status throughout, sandbox children,
serialize Python/Swift model residency, and retain per-clip events/differences.
Python scripts are developer reference/scoring tools only, never runtime or
build/install dependencies.

## Qualification

See `.build/qa/native-runtime/vn-stream/STATUS.md` and `REPORT.md` in the main
checkout for measured results and outstanding release gates. Compilation and
synthetic parity alone do not qualify a model. Do not switch the installed app
or advertise native Streaming as qualified until the real corpus, timed gap,
long-session retention, and cancellation checks pass.
