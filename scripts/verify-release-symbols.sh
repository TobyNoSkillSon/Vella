#!/usr/bin/env bash
# Verify the complete final symbol set, including the app and case-insensitive CLI name.
# Works on retained material or the extracted dSYM-only public sidecar.
set -euo pipefail
[[ $# == 2 && -d "$1/Contents" && -f "$2/UUIDS.txt" ]] || { echo 'usage: verify-release-symbols.sh APP SYMBOLS_DIRECTORY' >&2; exit 2; }
APP="$1"; SYMBOLS="$2"; expected=''
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do
  name="${path//\//-}"; dsym="$SYMBOLS/dSYMs/$name.dSYM"
  uuid="$(xcrun dwarfdump --uuid "$APP/Contents/$path" | awk '{print $2}')"
  [[ -n "$uuid" && -d "$dsym" && "$uuid" == "$(xcrun dwarfdump --uuid "$dsym" | awk '{print $2}')" ]] || {
    echo "Missing or mismatched dSYM: $path" >&2; exit 1;
  }
  xcrun dwarfdump --show-section-sizes "$dsym" | awk '$1 == "__debug_info" && $2 > 0 {found=1} END {exit !found}' || {
    echo "dSYM lacks DWARF debug information: $path" >&2; exit 1;
  }
  if [[ -d "$SYMBOLS/unstripped" ]]; then
    [[ "$uuid" == "$(xcrun dwarfdump --uuid "$SYMBOLS/unstripped/$name" | awk '{print $2}')" ]] || {
      echo "Missing or mismatched unstripped image: $path" >&2; exit 1;
    }
  fi
  expected+="$uuid $path"$'\n'
done
# Check after ALL writes: no UUIDS.txt entry may claim missing, clobbered or unrelated symbols.
diff -u <(printf '%s' "$expected" | LC_ALL=C sort) <(LC_ALL=C sort "$SYMBOLS/UUIDS.txt") || {
  echo 'UUIDS.txt does not match the complete shipped image set' >&2; exit 1;
}
echo 'Symbols verified: all five shipped images have matching UUIDs and DWARF dSYMs'
