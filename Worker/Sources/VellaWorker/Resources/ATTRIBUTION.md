# Public fast-path self-test clips

- `clip-a.wav` is LibriSpeech `5142-36377-0000` (3.38 s).
- `clip-b.wav` is LibriSpeech `672-122797-0073` (8.205 s).

16 kHz mono 16-bit PCM conversions of the public `Resources/Benchmarks/english-formatted-20m-v1/` FLAC source. LibriSpeech by Vassil Panayotov, Guoguo Chen, Daniel Povey, and Sanjeev Khudanpur; source https://www.openslr.org/12. Audio from LibriVox recordings, under Creative Commons Attribution 4.0 (`LICENSE-CC-BY-4.0.txt`). The corpus's written references were restored separately; neither clip carries reference text in the worker. These two clips exercise punctuation/case boundaries that distinguished an earlier fused-convolution rounding error; token IDs are compared with the loaded stock Swift model on the device.
