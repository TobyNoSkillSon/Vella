#!/usr/bin/env bash
# CI only (release.yml): make the release signing identity from the environment secrets available to scripts/build.sh.
#   ci-keychain.sh import   needs VELLA_SIGNING_P12_BASE64, VELLA_SIGNING_P12_PASSWORD, VELLA_SIGNING_SHA1, RUNNER_TEMP
#   ci-keychain.sh delete   removes the temporary keychain (run it even when the job fails)
# The identity is self-signed ("Vella Release Signing"): no Apple certificate and no trust setting is involved;
# codesign signs with it by SHA-1, and the designated requirement pins that certificate. Key and certificate go into
# a temporary keychain with a random password, prepended to the user search list. The p12 password reaches openssl
# through the environment, never on a command line; key files are deleted right after the import.
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
KEYCHAIN="$RUNNER_TEMP/vella-signing.keychain-db"
WORK="$RUNNER_TEMP/vella-signing"

case "${1:-}" in
  import)
    : "${VELLA_SIGNING_P12_BASE64:?}" "${VELLA_SIGNING_P12_PASSWORD:?}" "${VELLA_SIGNING_SHA1:?}"
    umask 077
    mkdir -p "$WORK"
    trap 'rm -P "$WORK"/*.pem 2>/dev/null || true; rm -rf "$WORK"' EXIT
    printf '%s' "$VELLA_SIGNING_P12_BASE64" | base64 -D > "$WORK/signing.p12"
    /usr/bin/openssl pkcs12 -in "$WORK/signing.p12" -passin env:VELLA_SIGNING_P12_PASSWORD -nocerts -nodes -out "$WORK/key.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -in "$WORK/signing.p12" -passin env:VELLA_SIGNING_P12_PASSWORD -nokeys -clcerts -out "$WORK/cert.pem" 2>/dev/null
    rm -f "$WORK/signing.p12"
    FINGERPRINT="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    [[ "$FINGERPRINT" == "$VELLA_SIGNING_SHA1" ]] || {
      echo "The p12 holds certificate $FINGERPRINT, not the pinned release identity $VELLA_SIGNING_SHA1" >&2; exit 1; }
    PASSWORD="$(/usr/bin/openssl rand -hex 24)"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import "$WORK/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
    security import "$WORK/cert.pem" -k "$KEYCHAIN" >/dev/null
    # codesign may use the key without a UI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
    # Prepend to the user search list, keeping the existing keychains.
    EXISTING=()
    while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; EXISTING+=("${line//\"/}"); done < <(security list-keychains -d user)
    security list-keychains -d user -s "$KEYCHAIN" "${EXISTING[@]}"
    security find-identity -p codesigning "$KEYCHAIN" | grep -q "$VELLA_SIGNING_SHA1" || {
      echo "No code-signing identity $VELLA_SIGNING_SHA1 in the imported p12" >&2; exit 1; }
    echo "Release signing identity $VELLA_SIGNING_SHA1 imported into a temporary keychain"
    ;;
  delete)
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK"
    ;;
  *) echo "usage: $0 import|delete" >&2; exit 2 ;;
esac
