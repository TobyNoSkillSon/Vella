# Contributing to Vella

Bug reports, model proposals, fixes and speed-ups are welcome. This file covers building and testing, the evidence a pull request needs, and how review works. Questions and early ideas belong in [Discussions](https://github.com/TobyNoSkillSon/Vella/discussions); security problems go through [SECURITY.md](SECURITY.md).

## Build from source

You need an Apple Silicon Mac and two toolchains:

- **Command Line Tools with Swift 6.3.3 or 6.4** (`xcode-select --install`; check with `/Library/Developer/CommandLineTools/usr/bin/swift --version`). All Swift code is compiled with it. Releases are built with 6.3.3; a 6.4 build still runs on macOS 26.
- **Full Xcode with its Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`). Xcode only compiles MLX's Metal shaders, with fast math off.

The split is deliberate. With Swift 6.4, a swift-collections function that nothing calls references a runtime symbol (`_swift_initBorrow`) that macOS 26 does not have, so an unmodified build aborts at launch there; `Worker/build-split.sh` links that reference weakly, so both 6.3.3 and 6.4 builds run on macOS 26. The shader setting is part of the qualified numerics (see [Dependencies](#dependencies)). The scripts do both halves:

```sh
scripts/build.sh                          # dist/Vella.app: app, both recognition helpers, the `vella` command, mlx.metallib
VELLA_APP_PATH=/tmp/Vella.app VELLA_REGISTER_APP=0 scripts/build.sh   # build elsewhere, leave Launch Services alone
VELLA_BUILD=source scripts/install.sh     # build this checkout and install it
```

`scripts/build.sh` builds the root package (the app) and `Worker/` (the helpers, through `Worker/build-split.sh`), then smoke-tests both helpers with stub models before assembly and again against the stripped, signed app. Signing uses `VELLA_SIGN_IDENTITY`, then the local `~/Library/Application Support/Vella/signing-identity` file, otherwise ad hoc; replacing an ad-hoc build can make macOS ask for Microphone and Accessibility access again. `VELLA_BUNDLE_ID=<id>` gives the built app another bundle identifier, so macOS keeps a development build's privacy permissions apart from an installed Vella's (in-app updates are off for any identifier other than `dev.vella.dictation`).

Both helper names invoke one image: `VellaStreamingWorker` is a relative symlink to `VellaWorker`, and the invoked name selects the protocol. Their source folders stay separate. Build the `VellaWorker` product, or use `Worker/build-split.sh` to create both invocation paths.

Activity Monitor, `top` and crash reports show both processes as **VellaWorker**, with signing identifier `VellaWorker`. `pgrep -x VellaStreamingWorker` matches the streaming invocation's argv, but does not restore a distinct kernel process name. Use the PID for `footprint`/`vmmap`; use the stack (`StreamingMain` versus `DictationMain`) to identify a crash's mode.

Shipped binaries are stripped. Plain/source builds retain no symbol directories. When `VELLA_RELEASE_SYMBOLS_DIR` is set, the build retains path-named dSYMs and unstripped copies outside the app and verifies every shipped UUID against them. `scripts/package-release.sh` publishes only the dSYMs, `UUIDS.txt` and symbolication note in a checksummed `Vella-VERSION-arm64-symbols.zip`; installers download only the app zip. Both worker modes use `MacOS-VellaWorker.dSYM`. Match the crash report's image UUID to the dSYM before symbolication. `scripts/verify-release-symbols.sh APP SYMBOLS_DIRECTORY` also checks an extracted sidecar.

Every `VELLA_*` switch the Swift code reads is listed, with its owner and whether it joins the fast-path gate key or is reported in status, in `Packages/VellaWire/Sources/VellaWire/EnvironmentSwitch.swift`.

`swift build` builds with whichever Swift you run it with; it is fine for compiling and for tests, not for shipping.

## Test

```sh
xcrun swift test          # the app package
scripts/test-worker.sh    # the Worker package: gate keys, admission, wire helpers (CPU only, Command Line Tools Swift)
xcrun swift test --package-path Packages/VellaWire   # the vocabulary the app and the helpers share
scripts/lint.sh           # swift-format (layout, .swift-format) and SwiftLint (rules, .swiftlint.yml); --fix reformats
```

The tests never touch your installed app, its settings, recordings or models. Tests that need a recognition helper use a temporary support directory and either a fake worker (a short script that speaks the helper's stdio protocol; it needs the `python3` of the Command Line Tools) or a built helper with `VELLA_STUB_MODELS=1`. Stub models need no weights and do no GPU work: they return fixed text but report load state, engine labels, fallbacks, residency and memory through the real code.

CI runs only the fast unit tests. The integration tests (everything that starts another program: the fake worker, a built helper, the `vella` binary, the installer scripts) skip when `CI=true` and run locally by default; `VELLA_INTEGRATION=1` runs them even under `CI=true`. Run the full suite locally before a pull request that touches the helpers, the CLI, the API or the scripts. Tests with a real model are opt-in through their own environment variables and never run in CI.

### Release check

```sh
scripts/release-check.sh            # everything CI and the release workflow check, run on your Mac
scripts/release-check.sh --ci       # the CI test set only (unit tests, CI=true)
scripts/release-check.sh --signed   # release-signing environment: check the "Vella Release Signing" identity as release.yml does
```

It runs the steps of `.github/workflows/ci.yml` and `release.yml` locally: tracked files are source only; Command Line Tools Swift 6.3.3 or 6.4 and the Metal Toolchain are present; `CHANGELOG.md` has a section for the version in `Resources/Info.plist` (it becomes the release notes); relative links in the public docs resolve; `scripts/lint.sh` is clean; `scripts/package-release.sh` builds, smoke-tests and zips the app into `.build/release-check/<time>/release/`; `SHA256SUMS` verifies; `xcrun swift test` passes. It prints one line per step and ends with the zip's path and SHA-256. It installs, uploads, tags and publishes nothing. Run it before a pull request that touches the build, the scripts or the docs, and before every tag.

Real-model parity and benchmarks need downloaded weights and a quiet GPU. The maintainer runs them on the reference Mac (an M5 Max) before a change that affects numerics is merged.

Bump `Resources/Info.plist`, `scripts/install-public.sh` and `scripts/install-release.sh` only in the release commit: the raw-from-main installer reads the current release version, so advancing it before that release exists breaks installs.

## Layout

| Path | What |
|---|---|
| `Sources/Vella` | The menu-bar app: recording, the Models table, helper supervision, the local API. No MLX. |
| `Sources/VellaCore` | App logic shared with tests: catalog, recommended precision, residency, memory, the API's request handling. |
| `Sources/VellaCLI` | The `vella` command (`status`, `models`, `transcribe`, `url`, `skill`, `diagnose`). |
| `Sources/VellaInstallTool` | The staged install with rollback used by the installers. |
| `Sources/VellaModelTool` | A retired stub, shipped only because 1.0.x in-app updaters require the file. |
| `Worker/` | A separate Swift package: the sandboxed recognition helpers (`VellaWorker` for Dictation, `VellaStreamingWorker` for Streaming), the vendored MLX speech models in `Worker/Sources/MLXAudioSTT` (each model folder has a README), the optimized kernels and their self-tests. |
| `Resources/` | `models.json` (catalog), `benchmarks.json` (measured figures), `SKILL.md` (agent skill), the calibration clip. |
| `docs/` | User guide, benchmark methods and images. |
| `Benchmarks/` | Public measurement/optimization kit and community results; audio is fetched from pinned upstreams. |

## Pull requests

Open an issue first for anything larger than a fix, so we can agree on the approach before you spend time on it. Then:

- Keep one change per pull request, matching the style of the surrounding code.
- Run `scripts/release-check.sh` (or at least `scripts/build.sh` and `xcrun swift test`, integration tests included, as above).
- Update the docs your change touches (README, `docs/USAGE.md`, `Resources/SKILL.md`, `AGENTS.md`) and add a line to `CHANGELOG.md` for anything a user would notice.
- Add no new dependencies without discussing them first. The app package has none, on purpose.
- Measure performance claims and say on what hardware (chip, memory, macOS). An unmeasured speed-up will not be merged.

The pull request template asks for these.

### Adding a model

Start with a **New model request** issue. A catalog model needs open weights with a licence that allows local use, an MLX checkpoint (or a conversion you can publish) and an architecture that mlx-swift can run. The Models table offers few models on purpose: each must serve a clear purpose the others do not (accuracy, size, languages, speed or another model family). A lower error rate elsewhere does not rule a model out, but a model that duplicates an offered one does not get in.

**A new checkpoint of a known architecture is a catalog entry plus a folder, not a new runtime.** Check `config.json`, tensors and tokenizer against the existing adapter. Add the family to `Resources/models.json`, pin the native 16-bit checkpoint's revision, sizes and licence, and let **Get** create its model folder. Add a small fixture/documentation folder alongside the existing architecture's tests explaining the checkpoint, conversion recipe and differences; do not commit weights. Declare int8/int4 as local affine group-64 derivations of the native checkpoint. Add a fixture test proving the entry decodes, resolves to the existing descriptor/runtime and preserves its dtype and derivation. Qualify with public speech before offering any tier; numbers remain absent until measured.

**A new architecture is engineering.** Implement its loader, input preparation and decoding in `Worker/Sources/MLXAudioSTT/<Family>/`. Conform to `SpeechModelRuntime` in `Worker/Sources/MLXAudioSTT/Runtime/SpeechModelRuntime.swift`: architecture, gate revision and required GPU feature family; use `DictationModelRuntime` for segment transcription or `StreamingModelRuntime` for genuinely incremental recognition. Register it in `ModelRuntimeRegistry`, add a descriptor under `Sources/VellaCore/Models/<Family>/` and register it in `ModelRegistry`; extend the wire architecture vocabulary and validation deliberately. Include a fixture test with a tiny local fixture or stub that exercises dispatch, loading, input shape, output and unsupported-config rejection without a weight download. Keep optimized kernels behind a self-test and a working Standard fallback.

For either route, the model's folder documents what it is, which optimizations were tried, their measured effect and hardware, the quality gate and rejected levers: a `README.md` in `Worker/Sources/MLXAudioSTT/<Family>/`, written by hand except for its measured-figures block, which `scripts/model-readmes.swift` fills from `Resources/benchmarks.json` and `Resources/models.json` (a new architecture also needs its folder in that script's `folders` map, in `Tests/VellaCoreTests/ModelDocsTests.swift`'s `folders` and switch/revision `pairs`, and in the `exclude` list of `Worker/Package.swift`, so SwiftPM does not warn about an unhandled file). The model lists in `Resources/SKILL.md` and `docs/USAGE.md` come from `scripts/agent-docs.swift`. Run both (`xcrun swift scripts/<name>.swift`) after changing either JSON file and commit the result; `ModelDocsTests` fails when a generated block is stale. The pull request must show:

1. **Parity.** Run the model's reference implementation (the authors' code or mlx-audio, at a named version or commit) and Vella on the same public audio, and give the word error rate of each and every transcript that differs. Include the script and the clip list so the result can be reproduced.
2. **Numbers.** Word error rate on a public set, speed (× real time) and memory, with the chip, memory and macOS they were measured on.

Before a model's figures go into `Resources/benchmarks.json`, the maintainer measures it with Vella's v2 benchmark (240 minutes, English and nine other languages) on the reference Mac, so every row of the table is comparable.

### Community measurement

Start at [Benchmarks/README.md](Benchmarks/README.md). The public kit contains the frozen full v2 and v2-quick manifests, upstream audio fetch/hash verification, exact scorer, serial installed-app API runner, quality gate, local result self-check and [result PR recipe](Benchmarks/results/README.md). One model/cell is enough. Quick quality is an estimate, never a full benchmark row. Nemotron's shipped-helper lane is labelled separately because 2.0.0 has no streaming API.

Ask consent before downloads, long runs, scheduling and opening an issue/PR. Exclude personal recordings and private support/log files. Record chip/GPU cores/RAM, macOS build, power, Vella version/build, precision and requested/actual path, engine and fallbacks. Speed/WER/RAM-only contributions are welcome; leave energy absent without the kit's powermetrics protocol and admin consent. Maintainers review by hand; no automatic validation or merge pipeline is required.

### Chip-specific optimizations

Follow the public [optimization guide](Benchmarks/OPTIMIZATION.md) and the owning model README before changing a kernel. The quick suite screens A/B; the full suite checks the task-quality gate.

Vella optimizes on hardware we own: M5 Max so far. Standard and working feature-gated fallbacks serve other Macs; no speed claim on them is a measurement until someone measures it. If a path is slow or disabled on your chip and you can fix it, you are welcome to:

- Put the new path **behind the load-time self-test** (`FastPathGate`). When a model loads, a child process runs the optimized and the stock MLX path on the bundled self-test clips and compares the tokens; the verdict is kept per model, GPU family/architecture/device name, macOS build and helper version. Gate on GPU family and features, never on chip names. If the test fails, or the path fails during a transcription, Vella must fall back to the stock path and say why: that is what the table's "MLX" label and `vella diagnose` show.
- Leave other chips' paths unchanged. Transcripts must stay within the parity limits: token-exact on the self-test clips, and English word error rate within 0.1 points of the stock path.
- Attach `vella diagnose` output from before and after the change on that chip, and name every chip you tested on. The maintainer checks the reference Mac for regressions.

### Dependencies

The helpers pin mlx-swift, mlx-swift-lm and swift-transformers to exact revisions in `Worker/Package.swift`. That combination, with the Swift 6.3.3 compiler and fast math off in the Metal shaders, is the one whose transcripts were checked against each model's reference. Changing any of them means running that parity check again, so dependency updates come through a pull request with parity evidence, not through automated updates. After a pin changes, run `scripts/third-party-notices.sh` and commit the updated `THIRD_PARTY_NOTICES.md`.

## AI-assisted contributions

Pull requests written with AI tools are welcome. Use a strong frontier model, read and understand every line before you submit, and say which model you used in the pull request. You are responsible for the change: the tests, the measurements and the answers to review comments.

Nothing is merged automatically. An AI reviewer may comment on pull requests, but a human maintainer reviews and merges every change.

## Licence

Vella 2.0 is licensed under the [MIT License](LICENSE). Published 0.x releases remain Apache-2.0. Contributions to 2.0 are accepted under the same MIT terms; there is no separate contributor agreement. Third-party code and model weights keep their own licences. "Vella" and its icon are the project's name and mark; a fork you distribute should use another name and icon.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
