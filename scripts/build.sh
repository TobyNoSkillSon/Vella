#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Local candidates may carry a newer version without changing public bootstrap pins.
[[ "${VELLA_BUILD_VERSION:-0.0.0}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid local build version' >&2; exit 1; }
[[ "${VELLA_BUILD_NUMBER:-0}" =~ ^[0-9]+$ ]] || { echo 'Invalid local build number' >&2; exit 1; }
# Source builds need no Apple account or certificate. Maintainers can opt into signing.
LOCAL_IDENTITY="$HOME/Library/Application Support/Vella/signing-identity"
if [[ -n "${VELLA_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$VELLA_SIGN_IDENTITY"
elif [[ -s "$LOCAL_IDENTITY" ]]; then
  IDENTITY="$(cat "$LOCAL_IDENTITY")"
else
  IDENTITY="-"
fi
# Never silently replace an existing certificate-backed installation with ad-hoc code.
APP="${VELLA_APP_PATH:-$PWD/dist/Vella.app}"
if [[ "$IDENTITY" == "-" && -d "$APP" ]] && codesign -dv "$APP" 2>&1 | grep -q '^Authority='; then
  echo 'Refusing to discard the installed signing identity. Configure VELLA_SIGN_IDENTITY or the local signing-identity file.' >&2
  exit 1
fi
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -Fq -- "$IDENTITY"; then
  echo 'Configured signing identity is unavailable. Installation left unchanged.' >&2
  exit 1
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo 'Local ad-hoc build: replacing this build can invalidate macOS privacy permissions.' >&2
fi
xcrun swift scripts/prepare-build.swift check
# Xcode's Metal compiler produces the pinned MLX shaders. The existing CLT
# Swift 6.3.3 compiler produces binaries that launch on this macOS release.
CLT=/Library/Developer/CommandLineTools
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" build -c release
Worker/build-split.sh
WORKER_BIN="$(DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" build --package-path Worker -c release --build-system native --show-bin-path)"
[[ -x "$WORKER_BIN/VellaWorker" && -x "$WORKER_BIN/VellaStreamingWorker" && -s "$WORKER_BIN/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  echo 'Native workers or pinned MLX shaders missing; build left installed app unchanged.' >&2; exit 1;
}
# Xcode 27's Swift 6.4 emits borrow symbols the macOS 26 Swift runtime lacks; such binaries die in dyld.
for binary in .build/release/Vella .build/release/VellaModelTool .build/release/VellaInstallTool .build/release/vella-cli "$WORKER_BIN/VellaWorker" "$WORKER_BIN/VellaStreamingWorker"; do
  if nm -u "$binary" | grep -Eq '_swift_(init|end)Borrow'; then
    echo "Unsupported Swift runtime borrow symbol in $(basename "$binary"); build left installed app unchanged." >&2; exit 1
  fi
done
# Smoke the helpers before touching the installed app: headless, answer on their pipe, exit on stdin EOF.
SMOKE="$PWD/.build/helper-smoke"
# App layout without an .app name or Info.plist, so LaunchServices never registers it as a Vella copy.
rm -rf "$SMOKE" && mkdir -p "$SMOKE/helpers/Contents/MacOS" "$SMOKE/helpers/Contents/Resources"
cp "$WORKER_BIN/VellaWorker" "$WORKER_BIN/VellaStreamingWorker" "$SMOKE/helpers/Contents/MacOS/"
cp -R "$WORKER_BIN/mlx-swift_Cmlx.bundle" "$WORKER_BIN/VellaWorker_VellaWorker.bundle" "$SMOKE/helpers/Contents/Resources/"
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swiftc" -O -sdk "$CLT/SDKs/MacOSX.sdk" scripts/check-helpers.swift -o "$SMOKE/check-helpers" 2>/dev/null
"$SMOKE/check-helpers" "$SMOKE/helpers" || { echo 'Helper smoke failed; build left installed app unchanged.' >&2; exit 1; }
# Compile first, then close only this exact installed app before replacing files.
RELAUNCH="$(VELLA_TARGET_APP="$APP" xcrun swift -e '
import AppKit
let path = ProcessInfo.processInfo.environment["VELLA_TARGET_APP"]!
let target = URL(fileURLWithPath: path)
let identity = (try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject
let apps = NSWorkspace.shared.runningApplications.filter {
    guard let url = $0.bundleURL else { return false }
    if url.path == path { return true }
    // The same bundle can be reached with different path casing or symlinks.
    guard let identity, let other = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject else { return false }
    return identity.isEqual(other)
}
if apps.count > 1 { fputs("Multiple instances found; refusing an ambiguous update.\n", stderr); exit(1) }
let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella/dictation-status.json")
if !apps.isEmpty, let data = try? Data(contentsOf: stateURL),
   let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let phase = state["phase"] as? String, ["recording", "preparing", "transcribing"].contains(phase) {
    fputs("Vella is busy. Finish or stop-and-keep dictation before updating; installation left unchanged.\n", stderr); exit(1)
}
apps.forEach { _ = $0.terminate() }
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
if apps.contains(where: { !$0.isTerminated }) { fputs("Vella did not quit; installation left unchanged.\n", stderr); exit(1) }
print(apps.isEmpty ? "0" : "1")
')"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Vella "$APP/Contents/MacOS/Vella"
cp "$WORKER_BIN/VellaWorker" "$WORKER_BIN/VellaStreamingWorker" .build/release/VellaModelTool "$APP/Contents/MacOS/"
# The installer tool travels inside the app so a release zip holds exactly one bundle.
mkdir -p "$APP/Contents/Helpers"
cp .build/release/VellaInstallTool "$APP/Contents/Helpers/VellaInstallTool"
# The `vella` command (product vella-cli: `vella` and `Vella` would collide in MacOS/); installers link ~/.local/bin/vella to it.
cp .build/release/vella-cli "$APP/Contents/Helpers/vella"
rm -f "$APP/Contents/MacOS/mlx.metallib"
rm -rf "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
cp -R "$WORKER_BIN/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
# Kernel self-test clips (public, CC BY 4.0); SwiftPM's Bundle.module looks in the app's Resources.
[[ -s "$WORKER_BIN/VellaWorker_VellaWorker.bundle/clip-a.wav" || -s "$WORKER_BIN/VellaWorker_VellaWorker.bundle/Contents/Resources/clip-a.wav" ]] || { echo 'VellaWorker self-test resources are missing.' >&2; exit 1; }
rm -rf "$APP/Contents/Resources/VellaWorker_VellaWorker.bundle"
cp -R "$WORKER_BIN/VellaWorker_VellaWorker.bundle" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VELLA_BUILD_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VELLA_BUILD_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${VELLA_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VELLA_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${VELLA_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VELLA_BUNDLE_ID" "$APP/Contents/Info.plist"
fi
cp Resources/models.json Resources/benchmark-policy.json Resources/AGENT_GUIDE.md Resources/SKILL.md "$APP/Contents/Resources/"
# models.json schema 2 covers both modes; older checkouts also had streaming-models.json.
if [[ -f Resources/streaming-models.json ]]; then cp Resources/streaming-models.json "$APP/Contents/Resources/"; else rm -f "$APP/Contents/Resources/streaming-models.json"; fi
# Measured numbers for the Models table (written by the lab benchmark harness).
if [[ -f Resources/benchmarks.json ]]; then cp Resources/benchmarks.json "$APP/Contents/Resources/"; fi
# Remove stale Python resources from in-place app updates; model weights and
# legacy user-owned Runtimes outside the app are intentionally untouched.
find "$APP/Contents/Resources" -type f \( -name '*.py' -o -name '*.pyc' \) -delete
mkdir -p "$APP/Contents/Resources/Calibration"
cp Resources/Calibration/manifest.json Resources/Calibration/text.txt Resources/Calibration/speech.wav Resources/Calibration/ATTRIBUTION.md Resources/Calibration/LICENSE-CC-BY-4.0.txt "$APP/Contents/Resources/Calibration/"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Benchmark audio and raw results are not part of the source tree or the app.
# Remove generated copies left by earlier installers, not any source or user recordings.
rm -rf "$APP/Contents/Resources/Benchmarks" "$APP/Contents/Resources/ReferenceResults"
# In-place updates from Python-era builds must not keep their runtime files.
rm -f "$APP/Contents/Resources/"*.py "$APP/Contents/Resources/setup-backend.sh" "$APP/Contents/Resources/runtime-requirements.txt"
rm -rf "$APP/Contents/Resources/__pycache__"
ICONSET="$PWD/.build/Vella.iconset"
mkdir -p "$ICONSET"
xcrun swift scripts/icon.swift "$PWD/.build/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" .build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" .build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Vella.icns"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/VellaWorker" "$APP/Contents/MacOS/VellaStreamingWorker" "$APP/Contents/MacOS/VellaModelTool" "$APP/Contents/Helpers/VellaInstallTool" "$APP/Contents/Helpers/vella"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/VellaWorker_VellaWorker.bundle" 2>/dev/null || true
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${VELLA_REGISTER_APP:-1}" == "1" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
if [[ "$RELAUNCH" == "1" ]]; then open "$APP"; fi
echo "$APP"
