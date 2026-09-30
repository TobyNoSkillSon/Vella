#!/usr/bin/env bash
# Prebuilt release installer (the default path of scripts/install.sh). No Xcode needed.
# Usage: install-release.sh VERSION [--dry-run]
# Downloads Vella-VERSION-arm64.zip and SHA256SUMS with curl, verifies everything before
# touching the installed app, then installs (install-prepared.sh). --dry-run stops after verifying.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Pass a release version, e.g. 1.0.0' >&2; exit 2; }
DRY_RUN=0
[[ "${2:-}" == '--dry-run' ]] && DRY_RUN=1
[[ $# -le 2 && ( $# -lt 2 || "$DRY_RUN" == 1 ) ]] || { echo 'Usage: install-release.sh VERSION [--dry-run]' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Vella requires an Apple Silicon Mac' >&2; exit 1; }
OS="$(sw_vers -productVersion)"
[[ "${OS%%.*}" -ge 26 ]] || { echo "Vella requires macOS 26 or newer ($OS)" >&2; exit 1; }
BASE="${VELLA_RELEASE_BASE_URL:-https://github.com/TobyNoSkillSon/Vella/releases/download/v$VERSION}"
# file:// serves a locally packaged release (scripts/package-release.sh) for testing.
[[ "$BASE" == https://* || "$BASE" == file://* ]] || { echo 'Release base URL must use HTTPS' >&2; exit 1; }
ZIP="Vella-$VERSION-arm64.zip"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/vella-release.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
fetch() { curl --fail --location --silent --show-error --proto '=https,file' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 1800 "$BASE/$1" -o "$TEMP/$1"; }
fetch SHA256SUMS
fetch "$ZIP"
EXPECTED="$(awk -v name="$ZIP" '$2 == name { print $1 }' "$TEMP/SHA256SUMS")"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Missing or ambiguous SHA-256 for $ZIP; nothing installed." >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$TEMP/$ZIP" | awk '{print $1}')"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$ACTUAL")" == "$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED")" ]] || {
  echo "SHA-256 mismatch for $ZIP; nothing installed." >&2; exit 1
}
echo "verified SHA-256 $ACTUAL  $ZIP"
# The hash detects corruption; a checksum fetched from the same release is not a signature.
zipinfo -1 "$TEMP/$ZIP" | awk '
  BEGIN { good = 1 } { n++; if (n > 20000 || $0 !~ /^Vella\.app(\/|$)/ || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /\\/) good = 0 }
  END { exit !(good && n > 0) }' || { echo 'Unsafe or unexpected archive entries; nothing installed.' >&2; exit 1; }
mkdir "$TEMP/unpacked"
ditto -x -k "$TEMP/$ZIP" "$TEMP/unpacked"
APP="$TEMP/unpacked/Vella.app"
for f in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker Helpers/VellaInstallTool; do
  [[ -x "$APP/Contents/$f" ]] || { echo "Release archive lacks Contents/$f; nothing installed." >&2; exit 1; }
done
[[ -s "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  echo 'Release archive lacks the Metal library; nothing installed.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || {
  echo 'App version does not match the requested release; nothing installed.' >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo 'App signature does not verify; nothing installed.' >&2; exit 1; }
echo "verified Vella.app $VERSION (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")): helpers, Metal library, signature"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "dry run: would install to ${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}; nothing installed"
  exit 0
fi
"$HERE/install-prepared.sh" "$APP"
