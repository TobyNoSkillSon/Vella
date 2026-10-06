#!/bin/bash
# Vella installer: curl -fsSL https://raw.githubusercontent.com/TobyNoSkillSon/Vella/main/scripts/install-public.sh | bash
# Downloads the prebuilt release with curl, verifies its SHA-256, contents, version and code signature before
# touching anything, installs it in ~/Applications, links the `vella` command and waits until Vella is ready.
# The same steps as scripts/install-release.sh and scripts/install-prepared.sh in the repository.
# Needs no Xcode or developer account. `bash -s -- --dry-run` verifies without installing.
set -euo pipefail

# Everything runs from main, so a download cut short executes nothing.
main() {
  local VERSION="${VELLA_VERSION:-2.0.1}" DRY_RUN=0
  MIGRATE=()
  for option in "$@"; do
    case "$option" in
      --dry-run) DRY_RUN=1 ;;
      --migrate-signing|--allow-downgrade) MIGRATE+=("$option") ;;
      *) fail 'Usage: install.sh [--dry-run] [--migrate-signing] [--allow-downgrade]' 2 ;;
    esac
  done
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VELLA_VERSION must be a release version, e.g. 2.0.1' 2
  [[ "$(uname -s)" == Darwin && "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == 1 ]] || fail 'Vella requires an Apple Silicon Mac'
  local OS; OS="$(sw_vers -productVersion)"
  [[ "${OS%%.*}" -ge 26 ]] || fail "Vella requires macOS 26 or newer ($OS)"

  local BASE="${VELLA_RELEASE_BASE_URL:-https://github.com/TobyNoSkillSon/Vella/releases/download/v$VERSION}"
  # file:// serves a locally packaged release (scripts/package-release.sh) for testing.
  [[ "$BASE" == https://* || "$BASE" == file://* ]] || fail 'Release base URL must use HTTPS'
  local ZIP="Vella-$VERSION-arm64.zip"
  TEMP="$(mktemp -d "${TMPDIR:-/tmp}/vella-release.XXXXXX")"
  trap 'rm -rf "$TEMP"' EXIT
  echo "Downloading Vella ${VERSION}…"
  fetch "$BASE" SHA256SUMS
  fetch "$BASE" "$ZIP"
  local EXPECTED ACTUAL
  EXPECTED="$(awk -v name="$ZIP" '$2 == name { print $1 }' "$TEMP/SHA256SUMS")"
  [[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || fail "Missing or ambiguous SHA-256 for $ZIP; nothing installed."
  ACTUAL="$(shasum -a 256 "$TEMP/$ZIP" | awk '{print $1}')"
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$ACTUAL")" == "$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED")" ]] || fail "SHA-256 mismatch for $ZIP; nothing installed."
  echo "verified SHA-256 $ACTUAL  $ZIP"
  # The hash detects corruption; a checksum fetched from the same release is not a signature.
  zipinfo -1 "$TEMP/$ZIP" | awk '
    BEGIN { good = 1 } { n++; if (n > 20000 || $0 !~ /^Vella\.app(\/|$)/ || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /\\/) good = 0 }
    END { exit !(good && n > 0) }' || fail 'Unsafe or unexpected archive entries; nothing installed.'
  mkdir "$TEMP/unpacked"
  ditto -x -k "$TEMP/$ZIP" "$TEMP/unpacked"
  local APP="$TEMP/unpacked/Vella.app" f
  for f in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker Helpers/VellaInstallTool; do
    [[ -x "$APP/Contents/$f" ]] || fail "Release archive lacks Contents/$f; nothing installed."
  done
  [[ -s "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || fail 'Release archive lacks the Metal library; nothing installed.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail 'App version does not match the requested release; nothing installed.'
  codesign --verify --deep --strict "$APP" || fail 'App signature does not verify; nothing installed.'
  echo "verified Vella.app $VERSION (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")): helpers, Metal library, signature"

  local DEST="${VELLA_DESTINATION_APP:-$HOME/Applications/Vella.app}"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "dry run: would install to $DEST; nothing installed"
    return 0
  fi
  install_prepared "$APP" "$DEST"
}

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

fail() { echo "$1" >&2; exit "${2:-1}"; }

fetch() {
  local http result=0
  http="$(curl --fail --location --silent --show-error --proto '=https,file' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 1800 --write-out '%{http_code}' "$1/$2" -o "$TEMP/$2" 2>"$TEMP/curl-error")" || result=$?
  [[ $result == 0 ]] && return 0
  [[ ! -s "$TEMP/curl-error" ]] || head -1 "$TEMP/curl-error" >&2
  if [[ "$http" == 404 ]]; then fail "Vella ${VELLA_VERSION:-2.0.1} is not available at the release URL; nothing was installed."
  else fail 'Vella could not download the release. Check your connection and try again; the installed app is unchanged.'; fi
}

# Staged swap with rollback, never mid-dictation or mid-load; the previous app is removed only after the new one
# reports ready (scripts/install-prepared.sh).
install_prepared() {
  local APP="$1" DEST="$2"
  local SUPPORT="${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}"
  local TOOL="$APP/Contents/Helpers/VellaInstallTool" OUTPUT PREVIOUS STATUS=0
  [[ -x "$TOOL" ]] || fail 'Prepared app lacks its installer tool; nothing installed.'
  mkdir -p "$(dirname "$DEST")"
  export VELLA_INSTALL_RETRY_COMMAND="curl -fsSL https://raw.githubusercontent.com/TobyNoSkillSon/Vella/main/scripts/install-public.sh | env VELLA_DESTINATION_APP=$(printf %q "$DEST") VELLA_VERSION=$(printf %q "${VELLA_VERSION:-2.0.1}") VELLA_SUPPORT_DIR=$(printf %q "$SUPPORT") VELLA_BIN_DIR=$(printf %q "${VELLA_BIN_DIR:-$HOME/.local/bin}") ${VELLA_RELEASE_BASE_URL:+VELLA_RELEASE_BASE_URL=$(printf %q "$VELLA_RELEASE_BASE_URL") }bash -s -- --migrate-signing"
  [[ " ${MIGRATE[*]-} " != *' --allow-downgrade '* ]] || VELLA_INSTALL_RETRY_COMMAND+=' --allow-downgrade'
  local ALLOW_DOWNGRADE=0
  [[ " ${MIGRATE[*]-} " != *' --allow-downgrade '* ]] || ALLOW_DOWNGRADE=1
  check_version "$APP" "$DEST" "$ALLOW_DOWNGRADE"
  OUTPUT="$("$TOOL" install --app "$APP" --destination "$DEST" --support "$SUPPORT" --keep-previous ${MIGRATE[@]+"${MIGRATE[@]}"})"
  PREVIOUS="$(sed -n 's/^previous: //p' <<<"$OUTPUT")"
  echo "installed $DEST; starting…"
  # The `vella` command for agents and scripts: a link into the app, so updates carry it along.
  local BIN="${VELLA_BIN_DIR:-$HOME/.local/bin}"
  if [[ -x "$DEST/Contents/Helpers/vella" ]]; then
    mkdir -p "$BIN" "$HOME/.local/share/vella"
    ln -sfn "$DEST/Contents/Helpers/vella" "$BIN/vella"
    printf '%s\n' "$DEST" > "$HOME/.local/share/vella/app-path"
    case ":$PATH:" in *":$BIN:"*) echo "command: $BIN/vella" ;; *) echo "command: $BIN/vella (add $BIN to PATH)" ;; esac
  fi
  "$TOOL" ready --app "$DEST" --support "$SUPPORT" --timeout "${VELLA_READY_TIMEOUT:-1800}" || STATUS=$?
  if [[ $STATUS -ne 0 ]]; then
    # Not ready, or degraded (exit 3: running, but a model configured to stay loaded is not). Keep the rollback copy.
    [[ -z "$PREVIOUS" ]] || echo "Previous app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST." >&2
    [[ $STATUS -eq 3 && "${VELLA_ACCEPT_DEGRADED:-0}" == 1 ]] && return 0
    exit 1
  fi
  if [[ " ${MIGRATE[*]-} " == *' --migrate-signing '* || "$OUTPUT" == *'signing-migrated:'* ]]; then
    [[ -z "$PREVIOUS" ]] || echo "Previous app kept at $PREVIOUS; to roll back, quit Vella and move it to $DEST."
  else
    [[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
  fi
}

main "$@"
