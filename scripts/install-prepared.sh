#!/usr/bin/env bash
# Install a verified, prepared Vella.app (used by install-release.sh and install.sh).
# Staged swap with rollback, never mid-dictation or mid-load; the previous app is removed
# only after the new one reports ready, except a signing migration retains it.
# Usage: install-prepared.sh <prepared Vella.app> [--migrate-signing] [--allow-downgrade]
set -euo pipefail
APP="${1:?usage: install-prepared.sh <prepared Vella.app>}"
DEST="${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}"
SUPPORT="${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}"
TOOL="$APP/Contents/Helpers/VellaInstallTool"
[[ -x "$TOOL" ]] || { echo 'Prepared app lacks its installer tool; nothing installed.' >&2; exit 1; }
export VELLA_INSTALL_RETRY_COMMAND="${VELLA_INSTALL_RETRY_COMMAND:-scripts/install-prepared.sh $(printf %q "$APP") --migrate-signing}"
VELLA_INSTALL_RETRY_COMMAND="env VELLA_DESTINATION_APP=$(printf %q "$DEST") VELLA_SUPPORT_DIR=$(printf %q "$SUPPORT") VELLA_BIN_DIR=$(printf %q "${VELLA_BIN_DIR:-$HOME/.local/bin}") ${VELLA_RELEASE_BASE_URL:+VELLA_RELEASE_BASE_URL=$(printf %q "$VELLA_RELEASE_BASE_URL") }$VELLA_INSTALL_RETRY_COMMAND"
EXTRA=()
shift
for option in "$@"; do
  case "$option" in
    --migrate-signing|--allow-downgrade) EXTRA+=("$option") ;;
    *) echo 'Usage: install-prepared.sh APP [--migrate-signing] [--allow-downgrade]' >&2; exit 2 ;;
  esac
done
[[ " ${EXTRA[*]-} " != *' --allow-downgrade '* ]] || VELLA_INSTALL_RETRY_COMMAND+=' --allow-downgrade'
export VELLA_INSTALL_RETRY_COMMAND
[[ -z "${VELLA_LAB_BUNDLE_ID:-}" ]] || EXTRA+=(--bundle-id "$VELLA_LAB_BUNDLE_ID")  # lab candidates only
# The downloaded tool can predate downgrade protection, so enforce it in the calling script too.
check_version() {
  local APP="$1" DEST="$2" ALLOW="$3" OLD NEW OLD_BUILD NEW_BUILD
  [[ -e "$DEST" ]] || return 0
  OLD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")" || return 1
  NEW="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" || return 1
  OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")" || return 1
  NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" || return 1
  [[ "$OLD" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ && "$NEW" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ &&
     "$OLD_BUILD" =~ ^[0-9]{1,9}$ && "$NEW_BUILD" =~ ^[0-9]{1,9}$ ]] || {
    echo "Cannot verify Vella's version/build; installation left unchanged." >&2; return 1;
  }
  [[ "$ALLOW" == 1 ]] && return 0
  if ! awk -v old="$OLD" -v new="$NEW" -v ob="$OLD_BUILD" -v nb="$NEW_BUILD" 'BEGIN {
    split(old,a,"."); split(new,b,"."); for (i=1;i<=3;i++) { if (b[i]+0 < a[i]+0) exit 1; if (b[i]+0 > a[i]+0) exit 0 }
    exit (nb+0 < ob+0)
  }'; then
    echo "Refusing to replace Vella $OLD (build $OLD_BUILD) with older Vella $NEW (build $NEW_BUILD). Installation left unchanged. To intentionally downgrade, repeat the original command with --allow-downgrade." >&2
    return 1
  fi
}

ALLOW_DOWNGRADE=0
[[ " ${EXTRA[*]-} " != *' --allow-downgrade '* ]] || ALLOW_DOWNGRADE=1
check_version "$APP" "$DEST" "$ALLOW_DOWNGRADE"
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
if [[ " ${EXTRA[*]-} " == *' --migrate-signing '* || "$OUTPUT" == *'signing-migrated:'* ]]; then
  [[ -z "$PREVIOUS" ]] || echo "Previous app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST."
else
  [[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
fi
