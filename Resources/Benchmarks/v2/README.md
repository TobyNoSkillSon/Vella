# Vella benchmark v2

About 4 hours of speech: about 70% English and 30% across Polish, German, French, Spanish, Swedish, Turkish, Japanese, Mandarin and Korean. Status: **in development**. It is not yet the published benchmark; v1 in `../v1/` remains canonical until v2 deliberately replaces it.

## Tracks

| Track | Clips | Score |
|---|---|---|
| Words | every English clip | lexical WER: case, punctuation, fillers and written/spoken number forms normalised |
| Formatting | English clips whose references were written by people with case and punctuation (Rev verbatim, LibriSpeech-PC, FLEURS) | case/punctuation-sensitive CER; fillers removed on both sides |
| Multilingual | 9 languages, ~7.5 min each (Polish ~12) | WER (pl de fr es sv tr) or CER (ja zh ko) per language; macro over the languages a model supports, with coverage k/9 |

Unsupported languages are reported as N/A, not 100%. Every score has a 95% cluster-bootstrap interval over the independent speaker/recording groups.

## Files

- `suite.json` — allocations: source, minutes, tracks, seed.
- `manifest.json` — every clip: id, file, SHA-256 of the FLAC and of its int16 PCM, duration, language, tracks, reference, source provenance (pinned revision, upstream path, offsets, channel).
- `tools/build.py` — `build` (select and extract), `merge`, `fetch` (rebuild audio from pinned upstream sources without reselection), `verify`.
- `tools/sources/*.py` — one adapter per source; each documents its selection, markup removal and channel policy.
- `scoring.py` — v2 scorer; rescoring from the transcripts in a `benchmark_worker.py` result.

## Getting the audio

Audio is not stored in this repository. Some sources do not permit redistributing the audio or leave it unclear, and the audio would bloat the source installer. Rebuild it from the pinned upstream sources:

```bash
python3 -m venv .venv && .venv/bin/pip install -r Resources/Benchmarks/v2/tools/requirements.txt
.venv/bin/python Resources/Benchmarks/v2/tools/build.py fetch
.venv/bin/python Resources/Benchmarks/v2/tools/build.py verify
```

`fetch` downloads about 5–6 GB of upstream files (some parquet files are range-read) into `Resources/Benchmarks/v2/.cache/`. It writes 16 kHz mono FLAC to `audio/` and verifies every clip's PCM hash.

## Running and scoring

```bash
python Resources/benchmark_worker.py benchmark --suite Resources/Benchmarks/v2 ... --output result.json
python Resources/Benchmarks/v2/scoring.py Resources/Benchmarks/v2/manifest.json result.json --support support.json
```

The v1 worker's own WER/formatting fields are v1 scoring; ignore them for v2.

## Sources and licences

| Source | Used for | Licence | Audio redistributable |
|---|---|---|---|
| AppTek Call-Center Dialogues (2026) | en, accented calls | CC BY-SA 4.0 | yes |
| VoiceArena Monsoon en-IN (2026) | en, Indian English | CC BY 4.0 | yes |
| EdAcc, University of Edinburgh (2023) | en, L1/L2 accents | CC BY-SA 4.0 | yes |
| NOTSOFAR-1, Microsoft (2024) | en, far-field meetings | CC BY 4.0 | yes |
| DiPCo, Amazon (2019) | en, dinner-party far-field | CDLA-Permissive-1.0 | yes |
| AMI Meeting Corpus | en, far-field meeting | CC BY 4.0 | yes |
| Earnings25, Bloomberg (2026) | en, Q4-2025 earnings calls | CC BY 4.0 (text) | unclear → fetched |
| Rev16, Earnings-21, Earnings-22 (Rev.com) | en, Formatting | CC BY-SA 4.0 (text) | unclear → fetched |
| LibriSpeech-PC (NVIDIA) / LibriSpeech | en, Formatting | CC BY 4.0 | yes |
| FLEURS, Google | en, pl, ja, zh | CC BY 4.0 | yes |
| Polish TEDx ASR eval (2026) | pl | CC BY-NC-ND 4.0 | no → fetched |
| Multilingual LibriSpeech | pl | CC BY 4.0 | yes |
| MUSCAT (2026) | de, tr | CC BY 4.0 | yes |
| MediaSpeech | fr, es, tr | CC BY 4.0 (dataset); source videos retain their owners' copyright | unclear → fetched |
| Klang Dialects (2026) | sv | CC BY 4.0 | yes |
| AISHELL-4 | zh, far-field meetings | CC BY-SA 4.0 | yes |
| Zeroth-Korean | ko | CC BY 4.0 | yes |
| HiKE (2025) | ko, Korean–English code-switching | Apache-2.0 | yes |

Reference texts in `manifest.json` are excerpts of these sources and remain under their licences. Pinned revisions, attribution text and evidence URLs are in each adapter's `SOURCE` block and in `manifest.json → sources`. No endorsement by any source owner is implied.

## Limits

- Scores measure agreement with one reference per clip. Formatting references are one editorial style, not the only correct one.
- Older sources (AMI, LibriSpeech, FLEURS, MLS, Rev/Earnings-21/22) are known or likely training material for some models. The 2025–26 sources carry most of the weight, but training-set exclusion cannot be proven. Per-source scores are always published.
- About 7.5 minutes per language is a screening size. Rank models within a language only when the paired bootstrap difference excludes zero.
- There is no conversational Japanese source; Japanese is read speech only.
