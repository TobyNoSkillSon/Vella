# Native runtime migration

The native installer replaces the Vella app bundle. It ignores any legacy `config.json` `executable` path and preserves existing settings, selected Dictation and Streaming models, model registry, weights, recordings, and the old Runtimes folder. A fresh installation downloads and selects the pinned Parakeet Q4 only after validation.

Existing `~/Library/Application Support/Vella/Runtimes/` folders are **not deleted**. They are legacy Python environments, not the native worker. Leave them in place while qualifying the new app and any rollback; remove them only as a separate, explicitly approved cleanup after confirming no old installation needs them.

The candidate prebuilt route uses `Vella-<version>.zip` and the matching `SHA256SUMS` from one GitHub release. Set `VELLA_NATIVE_INSTALL_MODE=source` to use the same release's verified source archive instead; source builds require full Xcode and the Metal Toolchain component, not Command Line Tools alone. Neither candidate installer is the published v0.8.8 endpoint until the release assets and signed native helper are ready.

Release staging is explicit: `scripts/package-native-source.sh <version> <output-dir>` archives a clean committed checkout; `scripts/package-native-release.sh <version> <signed Vella.app> <signed VellaInstallTool> <output-dir>` creates the prebuilt ZIP and SHA256SUMS (including the source archive when present). Inspect archive contents and signing identity before publication. These scripts do not publish anything.
