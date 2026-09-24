#!/bin/bash
# Candidate successor to the published v0.8.8 bootstrap; do not publish until assets exist.
set -euo pipefail
VERSION="0.9.0"
RELEASE="https://github.com/TobyNoSkillSon/Vella/releases/download/v$VERSION"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vella-native-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "Vella: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Apple Silicon macOS is required.'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail 'macOS 14 or newer is required.'
curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 60 "$RELEASE/SHA256SUMS" -o "$WORK/SHA256SUMS"
MODE="${VELLA_NATIVE_INSTALL_MODE:-prebuilt}"
case "$MODE" in
  prebuilt) ASSET="Vella-$VERSION.zip" ;;
  source) ASSET="Vella-$VERSION-source.tar.gz" ;;
  *) fail 'VELLA_NATIVE_INSTALL_MODE must be prebuilt or source.' ;;
esac
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset {print $1}' "$WORK/SHA256SUMS")"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Release checksum missing or ambiguous; nothing installed.'
curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 1800 "$RELEASE/$ASSET" -o "$WORK/$ASSET"
ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
EXPECTED="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail 'Release checksum mismatch; nothing installed.'
[[ "$(stat -f %z "$WORK/$ASSET")" -le 2147483648 ]] || fail 'Release archive exceeds the 2 GiB staging limit.'
if [[ "$MODE" == source ]]; then
  # The source path invokes the Xcode + Metal Toolchain check before building.
  mkdir "$WORK/source"
  tar -tzf "$WORK/$ASSET" | awk 'BEGIN {good=1} {count++; if (count > 20000 || $0 ~ /^\// || $0 ~ /(^|\/)\.\.\// || $0 ~ /\\/) good=0} END {exit !good}' || fail 'Unsafe source archive paths.'
  tar -xzf "$WORK/$ASSET" -C "$WORK/source"
  ROOTS=("$WORK/source"/*)
  [[ "${#ROOTS[@]}" == 1 && -f "${ROOTS[0]}/Package.swift" && -f "${ROOTS[0]}/scripts/install-native.sh" ]] || fail 'Expected one native Vella source folder.'
  "${ROOTS[0]}/scripts/install-native.sh"
  exit 0
fi
zipinfo -1 "$WORK/$ASSET" | awk '
  BEGIN {good=1; count=0}
  { count++; if (count > 20000 || $0 !~ /^(Vella\.app\/|VellaInstallTool$)/ || $0 ~ /(^|\/)\.\.\// || $0 ~ /^\// || $0 ~ /\\/) good=0 }
  END {exit !good}
' || fail 'Unsafe prebuilt archive entries.'
mkdir "$WORK/extracted"
ditto -x -k "$WORK/$ASSET" "$WORK/extracted"
[[ -d "$WORK/extracted/Vella.app" && -x "$WORK/extracted/VellaInstallTool" && -x "$WORK/extracted/Vella.app/Contents/MacOS/VellaModelTool" ]] || fail 'Native prebuilt archive is incomplete.'
codesign --verify --strict --deep "$WORK/extracted/Vella.app" || fail 'Prebuilt app signature is invalid.'
codesign --verify --strict "$WORK/extracted/VellaInstallTool" || fail 'Prebuilt installer signature is invalid.'
if [[ "${VELLA_NATIVE_VERIFY_ONLY:-0}" == 1 ]]; then
  echo 'Pinned prebuilt checksum and signatures verified; nothing installed.'
  exit 0
fi
"$WORK/extracted/VellaInstallTool" install \
  --app "$WORK/extracted/Vella.app" \
  --destination "${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}" \
  --support "${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}" \
  --catalog "$WORK/extracted/Vella.app/Contents/Resources/models.json" \
  --downloader "$WORK/extracted/Vella.app/Contents/MacOS/VellaModelTool"
