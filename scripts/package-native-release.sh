#!/bin/bash
# Offline candidate packaging only. Does not publish or install anything.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: package-native-release.sh <version> <signed Vella.app> <VellaInstallTool> <output-dir>' >&2; exit 2; }
VERSION="$1" APP="$2" TOOL="$3" OUT="$4"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -d "$APP" && -x "$TOOL" && -d "$OUT" ]] || { echo 'Invalid version, app, installer or output directory.' >&2; exit 1; }
codesign --verify --strict --deep "$APP"
codesign --verify --strict "$TOOL"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vella-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/Vella.app"
cp "$TOOL" "$WORK/VellaInstallTool"
ASSET="Vella-$VERSION.zip"
(cd "$WORK" && ditto -c -k --norsrc --noextattr --noacl . "$OUT/$ASSET")
echo "$(shasum -a 256 "$OUT/$ASSET" | awk '{print $1}')  $ASSET" > "$OUT/SHA256SUMS"
SOURCE="Vella-$VERSION-source.tar.gz"
if [[ -f "$OUT/$SOURCE" ]]; then
  echo "$(shasum -a 256 "$OUT/$SOURCE" | awk '{print $1}')  $SOURCE" >> "$OUT/SHA256SUMS"
fi
echo "$OUT/$ASSET"
