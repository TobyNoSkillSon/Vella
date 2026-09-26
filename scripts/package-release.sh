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
  "$PROJECT/scripts/build.sh" >/dev/null
APP="$STAGE/Vella.app"
codesign --verify --deep --strict "$APP"
ZIP="Vella-$VERSION-arm64.zip"
"$PROJECT/scripts/release-zip.sh" "$APP" "$STAGE/$ZIP"
LISTING="$(zipinfo -1 "$STAGE/$ZIP")"
for f in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella Resources/SKILL.md \
         Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib Resources/models.json Resources/diagnose-reference.json \
         Resources/LICENSE Resources/NOTICE Resources/THIRD_PARTY_NOTICES.md; do
  grep -qx "Vella.app/Contents/$f" <<<"$LISTING" || { echo "Archive is missing Vella.app/Contents/$f" >&2; exit 1; }
done
if grep -E '\.py$|/Benchmarks/|/ReferenceResults/' <<<"$LISTING" >&2; then echo 'Archive holds development files' >&2; exit 1; fi
shasum -a 256 "$STAGE/$ZIP" | awk -v zip="$ZIP" '{print $1 "  " zip}' > "$STAGE/SHA256SUMS"
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
mv "$STAGE/$ZIP" "$OUT/$ZIP"
mv "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS"
echo "Packaged locally: $OUT/$ZIP and $OUT/SHA256SUMS (version $VERSION build $BUILD; not published or installed)"
