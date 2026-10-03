#!/usr/bin/env bash
# Local optional DMG from a packaged release ZIP; never builds, installs, signs, uploads or publishes.
# Usage: scripts/package-dmg.sh RELEASE_DIRECTORY [VERSION] (default: Resources/Info.plist)
# Output: RELEASE_DIRECTORY/Vella-VERSION.dmg; add its SHA-256 to SHA256SUMS.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 && $# -le 2 ]] || { echo 'usage: package-dmg.sh RELEASE_DIRECTORY [VERSION]' >&2; exit 2; }
RELEASE="$(cd "$1" && pwd)"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT/Resources/Info.plist")}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 2; }
ZIP="Vella-$VERSION-arm64.zip"; NAME="Vella-$VERSION.dmg"; OUT="$RELEASE/$NAME"
[[ ! -e "$OUT" ]] || { echo "Output exists; preserving it: $OUT" >&2; exit 1; }
[[ -s "$RELEASE/$ZIP" && -s "$RELEASE/SHA256SUMS" ]] || { echo 'Release ZIP and SHA256SUMS required' >&2; exit 1; }
EXPECTED="$(awk -v name="$ZIP" '$2 == name {print $1}' "$RELEASE/SHA256SUMS")"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'Missing or ambiguous ZIP checksum' >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$RELEASE/$ZIP" | awk '{print $1}')"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED")" == "$ACTUAL" ]] || { echo 'ZIP checksum mismatch; no DMG made' >&2; exit 1; }
zipinfo -1 "$RELEASE/$ZIP" | awk '
  BEGIN { good=1 } { n++; if (n>20000 || $0 !~ /^Vella\.app(\/|$)/ || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /\\/ || $0 ~ /(^|\/)(\._[^\/]*|__MACOSX)(\/|$)/) good=0 }
  END { exit !(good && n>0) }' || { echo 'Unsafe release archive; no DMG made' >&2; exit 1; }
mkdir -p "$PROJECT/.build"
STAGE="$(mktemp -d "$PROJECT/.build/.dmg-stage.XXXXXX")"
MOUNT="$STAGE/mounted"
cleanup() {
  if mount | grep -F " on $MOUNT (" >/dev/null; then hdiutil detach -quiet "$MOUNT" || return; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir "$STAGE/unpacked" "$STAGE/image"
ditto -x -k "$RELEASE/$ZIP" "$STAGE/unpacked"
APP="$STAGE/unpacked/Vella.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || {
  echo 'ZIP app version mismatch; no DMG made' >&2; exit 1;
}
codesign --verify --deep --strict "$APP"
ditto --noqtn "$APP" "$STAGE/image/Vella.app"
codesign --verify --deep --strict "$STAGE/image/Vella.app"
ln -s /Applications "$STAGE/image/Applications"
cp "$PROJECT/Resources/DMG/FinderLayout" "$STAGE/image/.DS_Store"
hdiutil create -quiet -volname "Vella — Drag to Applications" -srcfolder "$STAGE/image" -format UDZO "$STAGE/$NAME"
hdiutil verify -quiet "$STAGE/$NAME"
mkdir "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$STAGE/$NAME"
codesign --verify --deep --strict "$MOUNT/Vella.app"
hdiutil detach -quiet "$MOUNT"
# Hash is local integrity evidence, not a signature. The app keeps the signature already in the ZIP.
(cd "$STAGE" && shasum -a 256 "$NAME") > "$STAGE/dmg.sum"
awk -v name="$NAME" '$2 != name' "$RELEASE/SHA256SUMS" > "$STAGE/SHA256SUMS"
cat "$STAGE/dmg.sum" >> "$STAGE/SHA256SUMS"
mv "$STAGE/$NAME" "$OUT"
mv "$STAGE/SHA256SUMS" "$RELEASE/SHA256SUMS"
echo "Packaged locally: $OUT (unsigned image; app signature unchanged; not published)"
