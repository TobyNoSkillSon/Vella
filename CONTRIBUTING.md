# Contributing to Vella

Bug reports, model proposals, fixes and speed-ups are welcome. This file covers building and testing, the evidence a pull request needs, and how review works. Questions and early ideas belong in [Discussions](https://github.com/TobyNoSkillSon/Vella/discussions); security problems go through [SECURITY.md](SECURITY.md).

## Build from source

You need an Apple Silicon Mac and two toolchains:

- **Command Line Tools with Swift 6.3.3** (`xcode-select --install`; check with `/Library/Developer/CommandLineTools/usr/bin/swift --version`). All Swift code is compiled with it.
- **Full Xcode with its Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`). Xcode only compiles MLX's Metal shaders, with fast math off.

The split is deliberate. Xcode 27's Swift 6.4 emits a runtime symbol (`_swift_initBorrow`) that macOS 26 does not have, so its binaries abort at launch. The shader setting is part of the qualified numerics (see [Dependencies](#dependencies)). The scripts do both halves:

```sh
scripts/build.sh                          # dist/Vella.app: app, both recognition helpers, VellaModelTool, the `vella` command, mlx.metallib
VELLA_APP_PATH=/tmp/Vella.app VELLA_REGISTER_APP=0 scripts/build.sh   # build elsewhere, leave Launch Services alone
VELLA_BUILD=source scripts/install.sh     # build this checkout and install it
```

`scripts/build.sh` builds the root package (the app) and `Worker/` (the helpers, through `Worker/build-split.sh`), then smoke-tests both helpers with stub models before it assembles the app. A source build is signed ad hoc unless you configure `VELLA_SIGN_IDENTITY`; replacing an ad-hoc build can make macOS ask for Microphone and Accessibility access again.

`swift build` builds with whichever Swift you run it with; it is fine for compiling and for tests, not for shipping.

## Test

```sh
xcrun swift test          # the app package
scripts/test-worker.sh    # the Worker package: gate keys, admission, wire helpers (CPU only, Command Line Tools Swift)
```

The tests never touch your installed app, its settings, recordings or models. Tests that need a recognition helper use a temporary support directory and either a fake worker (a short script that speaks the helper's stdio protocol; it needs the `python3` of the Command Line Tools) or a built helper with `VELLA_STUB_MODELS=1`. Stub models need no weights and do no GPU work: they return fixed text but report load state, engine labels, fallbacks, residency and memory through the real code.

CI runs only the fast unit tests. The integration tests (everything that starts another program: the fake worker, a built helper, the `vella` binary, the installer scripts) skip when `CI=true` and run locally by default; `VELLA_INTEGRATION=1` runs them even under `CI=true`. Run the full suite locally before a pull request that touches the helpers, the CLI, the API or the scripts. Tests with a real model are opt-in through their own environment variables and never run in CI.

### Release check

```sh
scripts/release-check.sh            # everything CI and the release workflow check, run on your Mac
scripts/release-check.sh --ci       # the CI test set only (unit tests, CI=true)
scripts/release-check.sh --signed   # maintainer: sign with "Vella Release Signing" and check the signature as release.yml does
```

It runs the steps of `.github/workflows/ci.yml` and `release.yml` locally: tracked files are source only; Command Line Tools Swift 6.3.3 and the Metal Toolchain are present; `CHANGELOG.md` has a section for the version in `Resources/Info.plist` (it becomes the release notes); relative links in the public docs resolve; `scripts/package-release.sh` builds, smoke-tests and zips the app into `.build/release-check/<time>/release/`; `SHA256SUMS` verifies; `xcrun swift test` passes. It prints one line per step and ends with the zip's path and SHA-256. It installs, uploads, tags and publishes nothing. Run it before a pull request that touches the build, the scripts or the docs, and before every tag.

Real-model parity and benchmarks need downloaded weights and a quiet GPU. The maintainer runs them on the reference Mac (an M5 Max) before a change that affects numerics is merged.

## Layout

| Path | What |
|---|---|
| `Sources/Vella` | The menu-bar app: recording, the Models table, helper supervision, the local API. No MLX. |
| `Sources/VellaCore` | App logic shared with tests: catalog, recommended precision, residency, memory, the API's request handling. |
| `Sources/VellaCLI` | The `vella` command (`status`, `models`, `transcribe`, `url`, `skill`, `diagnose`). |
| `Sources/VellaModelTool`, `Sources/VellaInstallTool` | Model downloads, and the staged install with rollback used by the installers. |
| `Worker/` | A separate Swift package: the sandboxed recognition helpers (`VellaWorker` for Dictation, `VellaStreamingWorker` for Streaming), the vendored MLX speech models in `Worker/Sources/MLXAudioSTT`, the optimized kernels and their self-tests. |
| `Resources/` | `models.json` (catalog), `benchmarks.json` (measured figures), `SKILL.md` (agent skill), the calibration clip. |
| `docs/` | The user guide and the GitHub Pages site (benchmark table and installer). |

## Pull requests

Open an issue first for anything larger than a fix, so we can agree on the approach before you spend time on it. Then:

- Keep one change per pull request, matching the style of the surrounding code.
- Run `scripts/release-check.sh` (or at least `scripts/build.sh` and `xcrun swift test`, integration tests included, as above).
- Update the docs your change touches (README, `docs/USAGE.md`, `Resources/SKILL.md`, `AGENTS.md`) and add a line to `CHANGELOG.md` for anything a user would notice.
- Add no new dependencies without discussing them first. The app package has none, on purpose.
- Measure performance claims and say on what hardware (chip, memory, macOS). An unmeasured speed-up will not be merged.

The pull request template asks for these.

### Proposing a model

Start with a **New model request** issue. A catalog model needs open weights with a licence that allows local use, an MLX checkpoint (or a conversion you can publish) and an architecture that mlx-swift can run. The Models table offers few models on purpose: each must serve a clear purpose the others do not (accuracy, size, languages, speed or another model family). A lower error rate elsewhere does not rule a model out, but a model that duplicates an offered one does not get in.

An implementation adds a family to `Resources/models.json` (every downloadable precision pinned to a repository revision and its exact size), the model code in `Worker/Sources/MLXAudioSTT/<Family>`, and its admission in `Worker/Sources/VellaWorker/Validation.swift`. The pull request must show:

1. **Parity.** Run the model's reference implementation (the authors' code or mlx-audio, at a named version or commit) and Vella on the same public audio, and give the word error rate of each and every transcript that differs. Include the script and the clip list so the result can be reproduced.
2. **Numbers.** Word error rate on a public set, speed (× real time) and memory, with the chip, memory and macOS they were measured on.

Before a model's figures go into `Resources/benchmarks.json`, the maintainer measures it with Vella's v2 benchmark (240 minutes, English and nine other languages) on the reference Mac, so every row of the table is comparable.

### Chip-specific optimizations

Vella's optimized paths (fused encoders, custom Metal kernels, the decoder loops) are meant to work on every Apple Silicon Mac. So far they have only been verified on an M5 Max. If a path is slow or disabled on your chip and you can fix it, you are welcome to:

- Put the new path **behind the load-time self-test** (`FastPathGate`). When a model loads, a child process runs the optimized and the stock MLX path on the bundled self-test clips and compares the tokens; the verdict is kept per model, GPU family, macOS build and helper version. Gate on GPU family and features, never on chip names. If the test fails, or the path fails during a transcription, Vella must fall back to the stock path and say why: that is what the table's "MLX" label and `vella diagnose` show.
- Leave other chips' paths unchanged. Transcripts must stay within the parity limits: token-exact on the self-test clips, and English word error rate within 0.1 points of the stock path.
- Attach `vella diagnose` output from before and after the change on that chip, and name every chip you tested on. The maintainer checks the reference Mac for regressions.

### Dependencies

The helpers pin mlx-swift, mlx-swift-lm and swift-transformers to exact revisions in `Worker/Package.swift`. That combination, with the Swift 6.3.3 compiler and fast math off in the Metal shaders, is the one whose transcripts were checked against each model's reference. Changing any of them means running that parity check again, so dependency updates come through a pull request with parity evidence, not through automated updates. After a pin changes, run `scripts/third-party-notices.sh` and commit the updated `THIRD_PARTY_NOTICES.md`.

## AI-assisted contributions

Pull requests written with AI tools are welcome. Use a strong frontier model, read and understand every line before you submit, and say which model you used in the pull request. You are responsible for the change: the tests, the measurements and the answers to review comments.

Nothing is merged automatically. An AI reviewer may comment on pull requests, but a human maintainer reviews and merges every change.

## Licence

Vella is licensed under [Apache-2.0](LICENSE). By submitting a contribution you agree that it is licensed under the same terms (section 5 of the licence); there is no separate contributor agreement. "Vella" and its icon are the project's name and mark and are not covered by the licence, so a fork you distribute should use another name and icon.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
