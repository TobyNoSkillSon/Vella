#!/usr/bin/env bash
# Strip shipped images before signing. Release packaging retains exact-build symbols outside the app.
# Usage: strip-release.sh APP [NEW_SYMBOLS_DIRECTORY]; plain builds retain nothing.
set -euo pipefail
[[ $# -ge 1 && $# -le 2 && -d "$1/Contents" ]] || { echo 'usage: strip-release.sh APP [NEW_SYMBOLS_DIRECTORY]' >&2; exit 2; }
APP="$1"; SYMBOLS="${2:-}"
if [[ -n "$SYMBOLS" ]]; then
  [[ ! -e "$SYMBOLS" ]] || { echo "Symbols directory already exists: $SYMBOLS" >&2; exit 2; }
  mkdir -p "$SYMBOLS/unstripped" "$SYMBOLS/dSYMs"
fi
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do
  # Basenames collide (Vella/vella) on case-insensitive APFS: include the bundle-relative path.
  name="${path//\//-}"
  uuid="$(xcrun dwarfdump --uuid "$APP/Contents/$path" | awk '{print $2}')"
  [[ -n "$uuid" ]] || { echo "Missing UUID: $path" >&2; exit 1; }
  if [[ -n "$SYMBOLS" ]]; then
    cp "$APP/Contents/$path" "$SYMBOLS/unstripped/$name"
    xcrun dsymutil "$SYMBOLS/unstripped/$name" -o "$SYMBOLS/dSYMs/$name.dSYM"
    echo "$uuid $path" >> "$SYMBOLS/UUIDS.txt"
  fi
  /usr/bin/strip -S -x "$APP/Contents/$path"
  [[ "$uuid" == "$(xcrun dwarfdump --uuid "$APP/Contents/$path" | awk '{print $2}')" ]] || { echo "strip changed UUID: $path" >&2; exit 1; }
done
if [[ -n "$SYMBOLS" ]]; then
  "$(dirname "$0")/verify-release-symbols.sh" "$APP" "$SYMBOLS"
  echo 'VellaStreamingWorker is a relative symlink to VellaWorker; both modes use MacOS-VellaWorker.dSYM. Match the crash image UUID before symbolication.' > "$SYMBOLS/README.txt"
  echo "Release symbols retained: $SYMBOLS" >&2
fi
