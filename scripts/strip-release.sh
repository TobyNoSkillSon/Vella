#!/usr/bin/env bash
# Keep exact-build symbolication material outside the app, then strip only shipped images before signing.
# Usage: strip-release.sh APP SYMBOLS_DIRECTORY (must not already exist)
set -euo pipefail
[[ $# == 2 && -d "$1/Contents" && ! -e "$2" ]] || { echo 'usage: strip-release.sh APP NEW_SYMBOLS_DIRECTORY' >&2; exit 2; }
APP="$1"; SYMBOLS="$2"
mkdir -p "$SYMBOLS/unstripped" "$SYMBOLS/dSYMs"
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do
  name="$(basename "$path")"
  cp "$APP/Contents/$path" "$SYMBOLS/unstripped/$name"
  xcrun dsymutil "$SYMBOLS/unstripped/$name" -o "$SYMBOLS/dSYMs/$name.dSYM"
  uuid="$(xcrun dwarfdump --uuid "$SYMBOLS/unstripped/$name" | awk '{print $2}')"
  [[ -n "$uuid" && "$uuid" == "$(xcrun dwarfdump --uuid "$SYMBOLS/dSYMs/$name.dSYM" | awk '{print $2}')" ]] || {
    echo "dSYM UUID mismatch: $name" >&2; exit 1;
  }
  /usr/bin/strip -S -x "$APP/Contents/$path"
  [[ "$uuid" == "$(xcrun dwarfdump --uuid "$APP/Contents/$path" | awk '{print $2}')" ]] || { echo "strip changed UUID: $name" >&2; exit 1; }
  echo "$uuid $path" >> "$SYMBOLS/UUIDS.txt"
done
echo 'VellaStreamingWorker is a relative symlink to VellaWorker; both modes use VellaWorker.dSYM.' > "$SYMBOLS/README.txt"
echo "Release symbols retained: $SYMBOLS" >&2
