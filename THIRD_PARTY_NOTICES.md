# Third-party components and data

Vella's original code is licensed under Apache 2.0; see LICENSE and NOTICE. That license does not replace the licenses of the assets and dependencies below.

## Runtime and models

The Swift application has no third-party Swift package dependencies. Explicit backend setup installs MLX Audio (`mlx-audio[stt]==0.5.1`, `mlx==0.32.2`) and its version-pinned Python dependencies through pip; see `Resources/runtime-requirements.txt`. Authorized model downloads use pinned, checksummed entries in `Resources/models.json` or `Resources/streaming-models.json`. Runtime dependencies and model weights are not committed or embedded in the app. They retain upstream licenses; model repositories, revisions and declared licenses are in the catalogs, and downloaded license files stay with each model. Nemotron 3.5's upstream card specifies OpenMDW-1.1 while its MLX converter cards retain older NVIDIA license metadata; the streaming catalog records that discrepancy. Voxtral Realtime weights are Apache-2.0. Redistributing a bundled runtime or weights requires reviewing their applicable notices separately.

## Benchmark audio and references (source checkout only)

- LibriSpeech: Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur, https://www.openslr.org/12/ — CC BY 4.0, derived from LibriVox recordings.
- LibriSpeech-PC formatted references: A. Meister et al., NVIDIA, https://www.openslr.org/145/ — CC BY 4.0.

`Resources/Benchmarks/english-mini-v1`, `english-20m-v1` and `english-formatted-20m-v1` retain their manifests, hashes, source attribution and license notices. Selected FLACs are unchanged. Formatting/scoring transformations and limitations are documented in README.md. No endorsement is implied. Full benchmark audio is not included in the app bundle.

## Calibration sample (included in the app)

`Resources/Calibration/speech.wav` is one 7.04-second LibriSpeech test-clean clip, with LibriSpeech-PC reference text, under CC BY 4.0. It is decoded to PCM16 WAV without trimming or gain changes. Attribution, full license and hashes accompany the sample and are copied into the app. It is not user speech or macOS synthesized speech.

## Apple assets

macOS system frameworks and SF Symbols are used under their applicable Apple terms. The app icon is drawn by Vella's own `scripts/icon.swift`; it is not a redistributed SF Symbol image.
