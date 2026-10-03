#!/usr/bin/env bash
# CPU-only regression for scripts/release-identity.sh: a development-signed build is refused for staging and upload,
# an ad hoc one is local-only, and only the pinned "Vella Release Signing" build passes. Real ad hoc signing plus a
# codesign shim for the identities that need a certificate.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$PROJECT/scripts/release-identity.sh"
ROOT="$(mktemp -d /tmp/vella-identity-fixture.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

REL_TEXT=$'Identifier=dev.vella.dictation\nSignature size=9000\nAuthority=Vella Release Signing\nTeamIdentifier=not set'
DEV_TEXT=$'Identifier=dev.vella.dictation\nAuthority=Apple Development: someone@example.com (ABCDE12345)\nAuthority=Apple Worldwide Developer Relations Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=ABCDE12345'
printf '%s\n' "$REL_TEXT" >"$ROOT/release.txt"
printf '%s\n' "$DEV_TEXT" >"$ROOT/dev.txt"
printf 'Identifier=x\nAuthority=Mac Developer: someone@example.com (X)\n' >"$ROOT/macdev.txt"
printf 'Identifier=x\nAuthority=Developer ID Application: Someone (TEAM)\n' >"$ROOT/devid.txt"
printf 'Identifier=x\nSignature=adhoc\nTeamIdentifier=not set\n' >"$ROOT/adhoc.txt"
printf 'Identifier=x\n' >"$ROOT/unsigned.txt"
for pair in release:release dev:development macdev:development devid:other adhoc:adhoc unsigned:unsigned; do
  got="$("$GUARD" text-class "$ROOT/${pair%%:*}.txt")"
  [[ "$got" == "${pair##*:}" ]] || fail "${pair%%:*} classified as '$got', expected '${pair##*:}'"
done

# Real ad hoc signing: classify, stage, zip, refuse upload.
APP="$ROOT/real/Vella.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
i=0
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do
  i=$((i + 1))
  echo "int main(void) {return $i;}" >"$ROOT/$i.c"
  xcrun clang "$ROOT/$i.c" -o "$APP/Contents/$path"
  codesign --force --sign - "$APP/Contents/$path" 2>/dev/null
done
cat >"$APP/Contents/Info.plist" <<'E'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.vella.dictation</string><key>CFBundleExecutable</key><string>Vella</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
E
mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents"
cat >"$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Info.plist" <<'E'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.vella.mlx-swift-Cmlx</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
E
codesign --force --sign - "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
[[ "$("$GUARD" classify "$APP")" == adhoc ]] || fail "real ad hoc app not classified adhoc"
mkdir "$ROOT/real-out"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ROOT/real-out/Vella-9.9.9-arm64.zip"
[[ "$("$GUARD" classify "$ROOT/real-out/Vella-9.9.9-arm64.zip")" == adhoc ]] || fail "real ad hoc zip not classified adhoc"
if "$GUARD" for-upload "$ROOT/real-out" 2>"$ROOT/err"; then fail "ad hoc zip accepted for upload"; fi
grep -q "not 'Vella Release Signing'" "$ROOT/err" || fail "upload refusal does not say why"
[[ "$("$GUARD" mark-local "$ROOT/real-out")" == adhoc ]] || fail "mark-local did not report adhoc"
[[ -e "$ROOT/real-out/LOCAL-ONLY-NOT-FOR-UPLOAD.txt" ]] || fail "mark-local did not write the marker"
if "$GUARD" for-upload "$ROOT/real-out" 2>"$ROOT/err"; then fail "a directory marked local-only was accepted"; fi
grep -q "local-only" "$ROOT/err" || fail "marker refusal does not say why"

# codesign shim: development, mixed and release identities without a certificate.
mkdir "$ROOT/bin"
cat >"$ROOT/bin/codesign" <<'E'
#!/usr/bin/env bash
# Signature and requirement shims remain per-target to expose a wrong-pin helper with the right CN.
target="${@: -1}"
if [[ " $* " == *" --verify "* ]]; then
  [[ -z "${FAKE_INVALID_PATH:-}" || "$target" != *"$FAKE_INVALID_PATH"* ]]; exit $?
fi
if [[ " $* " == *" -r- "* ]]; then
  case "$target" in
    */MacOS/Vella|*.app) id=dev.vella.dictation ;;
    */MacOS/VellaStreamingWorker) id=VellaWorker ;;
    */mlx-swift_Cmlx.bundle) id=org.vella.mlx-swift-Cmlx ;;
    *) id="$(basename "$target")" ;;
  esac
  pin="$FAKE_PIN"
  [[ -z "${FAKE_WRONG_PIN_PATH:-}" || "$target" != *"$FAKE_WRONG_PIN_PATH"* ]] || pin=0000
  echo "designated => identifier \"$id\" and certificate leaf = H\"$pin\"" >&2; exit 0
fi
if [[ -n "${FAKE_DEV_PATH:-}" && "$target" == *"$FAKE_DEV_PATH"* ]]; then cat "$FAKE_DEV_TEXT" >&2; else cat "$FAKE_TEXT" >&2; fi
E
chmod +x "$ROOT/bin/codesign"
FAKE="$ROOT/fake/Vella.app"
mkdir -p "$FAKE/Contents/MacOS" "$FAKE/Contents/Helpers" "$FAKE/Contents/Resources/mlx-swift_Cmlx.bundle"
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do : >"$FAKE/Contents/$path"; done
PIN="$(tr '[:upper:]' '[:lower:]' <<<2CA2587C8B85EF687E68950E405EC58CE31FC1C7)"
export FAKE_PIN="$PIN"
export FAKE_DEV_TEXT="$ROOT/dev.txt"
shimmed() { PATH="$ROOT/bin:$PATH" "$@"; }

# development identity everywhere
export FAKE_TEXT="$ROOT/dev.txt" FAKE_DEV_PATH=""
[[ "$(shimmed "$GUARD" classify "$FAKE")" == development ]] || fail "development app not classified development"
if shimmed "$GUARD" for-upload "$FAKE" 2>"$ROOT/err"; then fail "a development-signed app was accepted for upload"; fi
grep -q "signed as 'development'" "$ROOT/err" || fail "upload refusal does not say why"
grep -q "someone@example.com" "$ROOT/err" && fail "the upload refusal printed the developer's email"
mkdir "$ROOT/fake-out"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$FAKE" "$ROOT/fake-out/Vella-9.9.9-arm64.zip"
if shimmed "$GUARD" for-upload "$ROOT/fake-out" 2>/dev/null; then fail "a development-signed zip was accepted for upload"; fi
[[ "$(shimmed "$GUARD" mark-local "$ROOT/fake-out")" == development ]] || fail "mark-local did not report development"
grep -q "someone@example.com" "$ROOT/fake-out/LOCAL-ONLY-NOT-FOR-UPLOAD.txt" && fail "the marker holds the developer's email"
rm "$ROOT/fake-out/LOCAL-ONLY-NOT-FOR-UPLOAD.txt"

# one development-signed helper among release-signed code: still development
export FAKE_TEXT="$ROOT/release.txt" FAKE_DEV_PATH="Helpers/vella"
[[ "$(shimmed "$GUARD" classify "$FAKE")" == development ]] || fail "one development helper did not make the app development"
if shimmed "$GUARD" for-upload "$FAKE" 2>/dev/null; then fail "an app with one development helper was accepted"; fi

# release identity with the pinned requirement passes; a different requirement does not
export FAKE_DEV_PATH=""
shimmed "$GUARD" for-upload "$FAKE" >/dev/null || fail "a release-signed app with the pinned requirement was refused"
shimmed "$GUARD" for-upload "$ROOT/fake-out" >/dev/null || fail "a release-signed zip with the pinned requirement was refused"
[[ "$(shimmed "$GUARD" mark-local "$ROOT/fake-out")" == release ]] || fail "release-signed zip reported as local-only"
[[ ! -e "$ROOT/fake-out/LOCAL-ONLY-NOT-FOR-UPLOAD.txt" ]] || fail "a release-signed zip was marked local-only"
export FAKE_WRONG_PIN_PATH="Helpers/vella"
if shimmed "$GUARD" for-upload "$FAKE" 2>/dev/null; then fail "a release-signed app with another requirement was accepted"; fi

export FAKE_WRONG_PIN_PATH="Resources/mlx-swift_Cmlx.bundle"
if shimmed "$GUARD" for-upload "$FAKE" 2>/dev/null; then fail "wrong-pin MLX resource accepted"; fi
export FAKE_WRONG_PIN_PATH="" FAKE_INVALID_PATH="MacOS/VellaWorker"
if shimmed "$GUARD" for-upload "$FAKE" 2>/dev/null; then fail "invalid worker signature accepted"; fi
export FAKE_INVALID_PATH=""
cp "$ROOT/fake-out/Vella-9.9.9-arm64.zip" "$ROOT/fake-out/Vella-9.9.8-arm64.zip"
if shimmed "$GUARD" for-upload "$ROOT/fake-out" 2>/dev/null; then fail "ambiguous package directory accepted"; fi

echo "PASS: development signatures refused for upload (no email printed), ad hoc and marked builds refused for upload, only the pinned release identity accepted"
