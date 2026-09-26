#!/usr/bin/env bash
# Zip a signed app for release and check the archive (package-release.sh uses it).
#   release-zip.sh APP ZIP      write ZIP from APP, then check it
#   release-zip.sh --verify ZIP check an existing ZIP
# The archive carries no extended attributes: ditto would store them (com.apple.provenance, quarantine) as
# AppleDouble ._* entries, which /usr/bin/unzip extracts into the bundle and breaks its signature.
# Check: no ._* or __MACOSX entries, one .app at the top, and the app extracted by /usr/bin/unzip
# passes codesign --verify --deep --strict.
set -euo pipefail
usage() { echo "usage: $0 APP ZIP | $0 --verify ZIP" >&2; exit 2; }
if [[ "${1:-}" == --verify ]]; then
  [[ $# -eq 2 ]] || usage
  ZIP="$2"
else
  [[ $# -eq 2 && -d "$1" ]] || usage
  APP="$1"; ZIP="$2"
  [[ ! -e "$ZIP" ]] || { echo "Archive already exists: $ZIP" >&2; exit 1; }
  ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ZIP"
fi
LISTING="$(zipinfo -1 "$ZIP")"
if grep -E '(^|/)\._|^__MACOSX/' <<<"$LISTING" >&2; then
  echo "Archive holds AppleDouble (._*) or __MACOSX entries: $ZIP" >&2; exit 1
fi
TOP="$(awk -F/ 'NR==1 {print $1}' <<<"$LISTING")"
[[ "$TOP" == *.app ]] && ! grep -qvE "^$TOP(/|$)" <<<"$LISTING" || { echo "Archive must hold one .app at its top level: $ZIP" >&2; exit 1; }
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/release-zip.XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
/usr/bin/unzip -q "$ZIP" -d "$CHECK"
codesign --verify --deep --strict "$CHECK/$TOP" || { echo "App extracted with /usr/bin/unzip fails verification: $ZIP" >&2; exit 1; }
echo "Checked $ZIP: no AppleDouble entries; $TOP from /usr/bin/unzip verifies"
