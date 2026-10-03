#!/usr/bin/env bash
# Local release staging only: builds, zips and checksums. Installs, uploads and publishes nothing.
# Usage: package-release.sh [VERSION]   (default: Resources/Info.plist)
# Output: $VELLA_RELEASE_OUTPUT_DIR or .build/releases/VERSION/{Vella-VERSION-arm64.zip,SHA256SUMS}
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PROJECT/Resources/Info.plist"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
OUT="${VELLA_RELEASE_OUTPUT_DIR:-$PROJECT/.build/releases/$VERSION}"
[[ ! -e "$OUT" ]] || { echo "Output already exists; preserving it: $OUT" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac' >&2; exit 1; }
mkdir -p "$PROJECT/.build"
STAGE="$(mktemp -d "$PROJECT/.build/.package-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
VELLA_APP_PATH="$STAGE/Vella.app" VELLA_REGISTER_APP=0 VELLA_BUILD_VERSION="$VERSION" VELLA_BUILD_NUMBER="$BUILD" \
  VELLA_RELEASE_SYMBOLS_DIR="$STAGE/Symbols" \
  "$PROJECT/scripts/build.sh" >/dev/null
APP="$STAGE/Vella.app"
codesign --verify --deep --strict "$APP"
# Never stage a build signed with a developer's own identity: it exposes the developer's email and breaks CI-signed
# updates. Local checks may stage one with VELLA_PACKAGE_LOCAL_CHECK=1; the output is then marked as not uploadable.
SIGNED_AS="$("$PROJECT/scripts/release-identity.sh" assert-stageable "$APP")"
[[ "$(readlink "$APP/Contents/MacOS/VellaStreamingWorker")" == VellaWorker ]] || { echo 'Invalid streaming alias target' >&2; exit 1; }
ZIP="Vella-$VERSION-arm64.zip"
"$PROJECT/scripts/release-zip.sh" "$APP" "$STAGE/$ZIP"
LISTING="$(zipinfo -1 "$STAGE/$ZIP")"
for f in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella Resources/SKILL.md \
         Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib Resources/models.json Resources/diagnose-reference.json \
         Resources/LICENSE Resources/NOTICE Resources/THIRD_PARTY_NOTICES.md Resources/mlx-logo.pdf Resources/LICENSE-mlx; do
  grep -qx "Vella.app/Contents/$f" <<<"$LISTING" || { echo "Archive is missing Vella.app/Contents/$f" >&2; exit 1; }
done
if grep -E '\.py$|/Benchmarks/|/ReferenceResults/' <<<"$LISTING" >&2; then echo 'Archive holds development files' >&2; exit 1; fi
SYMBOLS_ZIP="Vella-$VERSION-arm64-symbols.zip"
# The unstripped copies are useful during local staging; dSYMs alone suffice for the public sidecar.
mkdir -p "$STAGE/public/Symbols"
cp -R "$STAGE/Symbols/dSYMs" "$STAGE/Symbols/UUIDS.txt" "$STAGE/Symbols/README.txt" "$STAGE/public/Symbols/"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$STAGE/public/Symbols" "$STAGE/$SYMBOLS_ZIP"
mkdir "$STAGE/symbols-check"
ditto -x -k "$STAGE/$SYMBOLS_ZIP" "$STAGE/symbols-check"
"$PROJECT/scripts/verify-release-symbols.sh" "$APP" "$STAGE/symbols-check/Symbols"
(cd "$STAGE" && shasum -a 256 "$ZIP" "$SYMBOLS_ZIP") > "$STAGE/SHA256SUMS"
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
if [[ "$SIGNED_AS" != release ]]; then
  echo "Signed as '$SIGNED_AS', not Vella Release Signing: for local checks only. Never upload this build; release only the CI build (.github/workflows/release.yml)." > "$OUT/LOCAL-ONLY-NOT-FOR-UPLOAD.txt"
fi
mv "$STAGE/$ZIP" "$OUT/$ZIP"
mv "$STAGE/$SYMBOLS_ZIP" "$OUT/$SYMBOLS_ZIP"
mv "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS"
echo "Packaged locally: $OUT/$ZIP, $OUT/$SYMBOLS_ZIP and $OUT/SHA256SUMS (version $VERSION build $BUILD; signed as $SIGNED_AS; not published or installed)"
[[ "$SIGNED_AS" == release ]] || echo "Marked local-only (LOCAL-ONLY-NOT-FOR-UPLOAD.txt): not for upload."
