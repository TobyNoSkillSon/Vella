#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
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
swift build -c release
# Compile first, then close only this exact installed app before replacing files.
RELAUNCH="$(VELLA_TARGET_APP="$APP" swift -e '
import AppKit
let path = ProcessInfo.processInfo.environment["VELLA_TARGET_APP"]!
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
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
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VELLA_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VELLA_BUNDLE_ID" "$APP/Contents/Info.plist"
fi
cp scripts/setup-backend.sh "$APP/Contents/Resources/"
cp Resources/models.json Resources/benchmark-policy.json Resources/benchmark_worker.py Resources/formatting_metrics.py Resources/AGENT_GUIDE.md "$APP/Contents/Resources/"
cp Resources/calibration_worker.py Resources/inference_worker.py Resources/runtime-requirements.txt "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Calibration"
cp Resources/Calibration/manifest.json Resources/Calibration/text.txt Resources/Calibration/speech.wav Resources/Calibration/ATTRIBUTION.md Resources/Calibration/LICENSE-CC-BY-4.0.txt "$APP/Contents/Resources/Calibration/"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Only compact table measurements ship. Source benchmark audio/raw transcripts stay in the repo.
# Remove generated copies left by earlier installers, not any source or user recordings.
rm -rf "$APP/Contents/Resources/Benchmarks" "$APP/Contents/Resources/ReferenceResults"
"${PYTHON:-python3}" - "$APP/Contents/Resources/ReferenceResults" <<'PYDATA'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
policy = json.loads(pathlib.Path('Resources/benchmark-policy.json').read_text())
for path in pathlib.Path('Resources/ReferenceResults').glob('*.json'):
    value = json.loads(path.read_text())
    if value['suiteID'] != policy['suiteID'] or value['suiteHash'] != policy['suiteHash'] or value['repeats'] < policy['minimumRepeats']: continue
    if policy.get('scorerSHA256') and value.get('formatting', {}).get('scorerSHA256') != policy['scorerSHA256']: continue
    if policy.get('lexicalNormalizerSHA256') and value.get('formatting', {}).get('lexicalNormalizerSHA256') != policy['lexicalNormalizerSHA256']: continue
    value['clips'] = []
    (out/path.name).write_text(json.dumps(value, separators=(',', ':')) + '\n')
PYDATA
ICONSET="$PWD/.build/Vella.iconset"
mkdir -p "$ICONSET"
swift scripts/icon.swift "$PWD/.build/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" .build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" .build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Vella.icns"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
if [[ "${VELLA_REGISTER_APP:-1}" == "1" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
if [[ "$RELAUNCH" == "1" ]]; then open "$APP"; fi
echo "$APP"
