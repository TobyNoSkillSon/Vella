#!/usr/bin/env bash
# CI only (release.yml): make a signing certificate from repository secrets available to scripts/build.sh.
#   ci-keychain.sh import   needs VELLA_SIGNING_P12_BASE64, VELLA_SIGNING_P12_PASSWORD, VELLA_SIGNING_IDENTITY, RUNNER_TEMP
#   ci-keychain.sh delete   removes the temporary keychain (run it even when the job fails)
# The certificate goes into a temporary keychain with a random password, added to the user search list so codesign
# and `security find-identity` see it. The .p12 file is deleted right after the import. The Apple WWDR G3 intermediate
# (pinned by SHA-256) is added so an Apple Development certificate validates without the maintainer's login keychain.
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
KEYCHAIN="$RUNNER_TEMP/vella-signing.keychain-db"
WWDR_URL=https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
WWDR_SHA256=dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f

case "${1:-}" in
  import)
    : "${VELLA_SIGNING_P12_BASE64:?}" "${VELLA_SIGNING_P12_PASSWORD:?}" "${VELLA_SIGNING_IDENTITY:?}"
    umask 077
    P12="$RUNNER_TEMP/vella-signing.p12"
    trap 'rm -f "$P12"' EXIT
    printf '%s' "$VELLA_SIGNING_P12_BASE64" | base64 -D > "$P12"
    PASSWORD="$(openssl rand -hex 24)"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$VELLA_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    rm -f "$P12"
    curl --fail --silent --show-error --location --proto '=https' --max-time 60 "$WWDR_URL" -o "$RUNNER_TEMP/wwdr-g3.cer"
    [[ "$(shasum -a 256 "$RUNNER_TEMP/wwdr-g3.cer" | awk '{print $1}')" == "$WWDR_SHA256" ]] || { echo 'WWDR G3 certificate hash mismatch' >&2; exit 1; }
    security import "$RUNNER_TEMP/wwdr-g3.cer" -k "$KEYCHAIN" >/dev/null 2>&1 || true   # already present is fine
    # codesign may use the key without a UI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
    # Prepend to the user search list, keeping the existing keychains.
    EXISTING=()
    while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; EXISTING+=("${line//\"/}"); done < <(security list-keychains -d user)
    security list-keychains -d user -s "$KEYCHAIN" "${EXISTING[@]}"
    security find-identity -v -p codesigning | grep -Fq -- "$VELLA_SIGNING_IDENTITY" || {
      echo 'The imported certificate is not a valid code-signing identity matching VELLA_SIGNING_IDENTITY' >&2
      security find-identity -v -p codesigning "$KEYCHAIN" | sed -E 's/"[^"]*"/"…"/' >&2   # counts and hashes, no names
      exit 1
    }
    echo "Signing identity imported into a temporary keychain"
    ;;
  delete)
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -f "$RUNNER_TEMP/vella-signing.p12" "$RUNNER_TEMP/wwdr-g3.cer"
    ;;
  *) echo "usage: $0 import|delete" >&2; exit 2 ;;
esac
