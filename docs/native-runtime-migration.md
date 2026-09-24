# Native runtime migration

The native installer replaces the Vella app bundle. It ignores any legacy `config.json` `executable` path and preserves existing settings, selected Dictation and Streaming models, model registry, weights, recordings, and the old Runtimes folder. A fresh installation downloads and selects the pinned Parakeet Q4 only after validation.

Existing `~/Library/Application Support/Vella/Runtimes/` folders are **not deleted**. They are legacy Python environments, not the native worker. Leave them in place while qualifying the new app and any rollback; remove them only as a separate, explicitly approved cleanup after confirming no old installation needs them.

The candidate prebuilt route uses `Vella-<version>.zip` and the matching `SHA256SUMS` from one GitHub release. Set `VELLA_NATIVE_INSTALL_MODE=source` to use the same release's verified source archive instead; source builds require both Command Line Tools Swift and full Xcode with its Metal Toolchain. On the tested macOS 26.6 host, the working split is CLT Swift 6.3.3 plus Xcode Metal 32023.921; an Xcode 27 Swift 6.4-built helper does not launch. Fresh-machine source building remains unqualified. Neither candidate installer is the published v0.8.8 endpoint until the release assets and signed native helpers are ready.

Release staging is explicit: `scripts/package-native-source.sh <version> <output-dir>` archives a clean committed checkout; `scripts/package-native-release.sh <version> <signed Vella.app> <signed VellaInstallTool> <output-dir>` creates the prebuilt ZIP and SHA256SUMS (including the source archive when present). Inspect archive contents and signing identity before publication. These scripts do not publish anything.
