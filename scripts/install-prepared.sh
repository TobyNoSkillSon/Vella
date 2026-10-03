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
[[ "${2:-}" == --migrate-signing ]] && EXTRA+=(--migrate-signing)
[[ -z "${VELLA_LAB_BUNDLE_ID:-}" ]] || EXTRA+=(--bundle-id "$VELLA_LAB_BUNDLE_ID")  # lab candidates only
OUTPUT="$("$TOOL" install --app "$APP" --destination "$DEST" --support "$SUPPORT" --keep-previous ${EXTRA[@]+"${EXTRA[@]}"})"
PREVIOUS="$(sed -n 's/^previous: //p' <<<"$OUTPUT")"
echo "installed $DEST; starting…"
# The `vella` command for agents and scripts: a link into the app, so updates carry it along.
BIN="${VELLA_BIN_DIR:-$HOME/.local/bin}"
if [[ -x "$DEST/Contents/Helpers/vella" ]]; then
  mkdir -p "$BIN" "$HOME/.local/share/vella"
  ln -sfn "$DEST/Contents/Helpers/vella" "$BIN/vella"
  printf '%s\n' "$DEST" > "$HOME/.local/share/vella/app-path"
  case ":$PATH:" in *":$BIN:"*) echo "command: $BIN/vella" ;; *) echo "command: $BIN/vella (add $BIN to PATH)" ;; esac
fi
STATUS=0
"$TOOL" ready --app "$DEST" --support "$SUPPORT" --timeout "${VELLA_READY_TIMEOUT:-1800}" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
  # Not ready, or degraded (exit 3: running, but a model configured to stay loaded is not). Keep the rollback copy.
  [[ -z "$PREVIOUS" ]] || echo "Previous app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST." >&2
  # VELLA_ACCEPT_DEGRADED=1: an explicit opt-in to finish a degraded install; the rollback copy is still kept.
  [[ $STATUS -eq 3 && "${VELLA_ACCEPT_DEGRADED:-0}" == 1 ]] && exit 0
  exit 1
fi
# Ready: the previous app is no longer needed as a rollback.
if [[ "${2:-}" == --migrate-signing || "$OUTPUT" == *'signing-migrated:'* ]]; then
  [[ -z "$PREVIOUS" ]] || echo "Previous self-built app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST."
else
  [[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
fi
