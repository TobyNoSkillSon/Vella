#!/usr/bin/env bash
# Install or update Vella from this checkout.
# Default: the prebuilt, checksum-verified release matching Resources/Info.plist (no Xcode needed).
# VELLA_BUILD=source: build this checkout (needs Command Line Tools, Xcode and its Metal Toolchain).
# Both refuse while Vella is recording, transcribing or loading, and keep the previous app until ready.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
case "${VELLA_BUILD:-release}" in
  release)
    RETRY_VERSION="$VERSION"; [[ "${1:-}" == --* || -z "${1:-}" ]] || RETRY_VERSION="$1"
    export VELLA_INSTALL_RETRY_COMMAND="scripts/install.sh $(printf %q "$RETRY_VERSION") --migrate-signing"
    if [[ "${1:-}" == --* ]]; then
      exec scripts/install-release.sh "$VERSION" "$@"
    fi
    exec scripts/install-release.sh "${1:-$VERSION}" "${@:2}"
    ;;
  source)
    SOURCE_FLAGS=()
    [[ "${1:-}" != --allow-downgrade ]] || { SOURCE_FLAGS=(--allow-downgrade); shift; }
    if [[ $# -gt 0 ]]; then
      [[ "$1" != --dry-run ]] || { echo '--dry-run is available for release installs only; nothing built or installed.' >&2; exit 2; }
      echo 'Source install accepts only --allow-downgrade; nothing built or installed. Usage: VELLA_BUILD=source scripts/install.sh [--allow-downgrade]' >&2; exit 2
    fi
    ;;
  *) echo 'VELLA_BUILD must be release or source' >&2; exit 2 ;;
esac
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == 1 ]] || { echo 'Vella requires an Apple Silicon Mac' >&2; exit 1; }
OS="$(sw_vers -productVersion)"; [[ "${OS%%.*}" -ge 26 ]] || { echo "Vella requires macOS 26 or newer ($OS)" >&2; exit 1; }
[[ -x /Library/Developer/CommandLineTools/usr/bin/swift ]] || { echo 'Command Line Tools Swift is required. Fix: xcode-select --install' >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || {
  echo 'Full Xcode is required for the Metal shaders. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer' >&2; exit 1; }
xcrun metal --version >/dev/null 2>&1 || { echo 'Metal Toolchain is missing. Fix: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vella-source.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "building Vella $VERSION from source…"
VELLA_APP_PATH="$WORK/Vella.app" VELLA_REGISTER_APP=0 scripts/build.sh >"$WORK/build.log" 2>&1 || {
  tail -20 "$WORK/build.log" >&2; echo 'Build failed; installed app unchanged.' >&2; exit 1; }
scripts/install-prepared.sh "$WORK/Vella.app" ${SOURCE_FLAGS[@]+"${SOURCE_FLAGS[@]}"}
