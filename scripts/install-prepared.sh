#!/usr/bin/env bash
# Install a verified, prepared Vella.app (used by install-release.sh and install.sh).
# Staged swap with rollback, never mid-dictation or mid-load; the previous app is removed
# only after the new one reports ready. Usage: install-prepared.sh <prepared Vella.app>
set -euo pipefail
APP="${1:?usage: install-prepared.sh <prepared Vella.app>}"
DEST="${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}"
SUPPORT="${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}"
TOOL="$APP/Contents/Helpers/VellaInstallTool"
[[ -x "$TOOL" ]] || { echo 'Prepared app lacks its installer tool; nothing installed.' >&2; exit 1; }
EXTRA=()
[[ -z "${VELLA_LAB_BUNDLE_ID:-}" ]] || EXTRA=(--bundle-id "$VELLA_LAB_BUNDLE_ID")  # lab candidates only
OUTPUT="$("$TOOL" install --app "$APP" --destination "$DEST" --support "$SUPPORT" --keep-previous ${EXTRA[@]+"${EXTRA[@]}"})"
PREVIOUS="$(sed -n 's/^previous: //p' <<<"$OUTPUT")"
echo "installed $DEST; starting…"
if ! "$TOOL" ready --app "$DEST" --support "$SUPPORT" --timeout "${VELLA_READY_TIMEOUT:-1800}"; then
  [[ -z "$PREVIOUS" ]] || echo "Previous app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST." >&2
  exit 1
fi
# Ready: the previous app is no longer needed as a rollback.
[[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
