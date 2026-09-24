#!/bin/bash
# Source-build fallback. Stages a native app before touching the installed copy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vella-native-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export VELLA_APP_PATH="$WORK/Vella.app" VELLA_REGISTER_APP=0
"$ROOT/scripts/build.sh"
[[ -x "$ROOT/.build/release/VellaInstallTool" ]] || { echo 'Native installer tool was not built.' >&2; exit 1; }
if [[ "${VELLA_NATIVE_VERIFY_ONLY:-0}" == 1 ]]; then
  echo 'Native source build and staged bundle verified; nothing installed.'
  exit 0
fi
"$ROOT/.build/release/VellaInstallTool" install \
  --app "$WORK/Vella.app" \
  --destination "${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}" \
  --support "${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}" \
  --catalog "$ROOT/Resources/models.json" \
  --downloader "$ROOT/.build/release/VellaModelTool"
