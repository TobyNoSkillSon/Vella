#!/usr/bin/env bash
# Which identity signed a Vella build, and whether it may be uploaded. A zip signed with a developer's own Apple
# Development identity exposes that developer's email in `codesign -dvv`, and an app installed from it rejects every
# later update signed with "Vella Release Signing". Such a build is for local checks only and must never be uploaded.
#
#   release-identity.sh classify APP|ZIP       print release | development | adhoc | unsigned | other | mixed
#   release-identity.sh mark-local DIR         write LOCAL-ONLY-NOT-FOR-UPLOAD.txt into a package directory whose zip is
#                                              not signed by Vella Release Signing (release-check.sh calls this)
#   release-identity.sh for-upload PATH        exit 0 only for a release-signed zip or app, or a directory whose
#                                              Vella-*-arm64.zip is release-signed with the pinned designated requirement
#                                              and which carries no LOCAL-ONLY marker; refuses everything else
#   release-identity.sh text-class FILE        classify one saved `codesign -dvv` output (tests)
# Names of non-release identities are never printed: a development identity's name is the developer's email.
set -euo pipefail
PIN_SHA1=2CA2587C8B85EF687E68950E405EC58CE31FC1C7   # "Vella Release Signing", same pin as release.yml
MARKER=LOCAL-ONLY-NOT-FOR-UPLOAD.txt
BINARIES=(MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella Resources/mlx-swift_Cmlx.bundle)

die() { echo "release-identity: $*" >&2; exit 1; }

# One `codesign -dvv` output on stdin -> release | development | adhoc | unsigned | other
classify_text() {
  local text leaf
  text="$(cat)"
  if grep -q '^Signature=adhoc' <<<"$text"; then echo adhoc; return; fi
  leaf="$(sed -n 's/^Authority=//p' <<<"$text" | sed -n '1p')"
  case "$leaf" in
    "") echo unsigned ;;
    "Vella Release Signing") echo release ;;
    "Apple Development:"*|"Mac Developer:"*|"iPhone Developer:"*|"Apple Distribution:"*|"3rd Party Mac Developer"*) echo development ;;
    *) echo other ;;
  esac
}

# Overall class of an app bundle: the app itself and every helper must agree; any development signature wins.
classify_app() {
  local app="$1" f c target classes=()
  [[ -d "$app" ]] || die "not an app bundle: $app"
  for f in "" "${BINARIES[@]}"; do
    [[ -z "$f" ]] && target="$app" || target="$app/Contents/$f"
    [[ -e "$target" ]] || { classes+=(unsigned); continue; }
    c="$(codesign -dvv "$target" 2>&1 | classify_text)"
    classes+=("$c")
  done
  local first="${classes[0]}" all_same=1
  for c in "${classes[@]}"; do
    [[ "$c" == development ]] && { echo development; return; }
    [[ "$c" == "$first" ]] || all_same=0
  done
  if [[ $all_same == 1 ]]; then echo "$first"; else echo mixed; fi
}

# ZIP -> extracted app in a temporary directory, which the caller removes.
unpack() {
  local zip="$1" dir="$2" app
  /usr/bin/unzip -q "$zip" -d "$dir" || die "cannot unzip $zip"
  app="$(find "$dir" -maxdepth 1 -name '*.app' -print | sed -n '1p')"
  [[ -n "$app" ]] || die "no .app at the top of $zip"
  echo "$app"
}

classify_path() {
  local path="$1" tmp app
  if [[ -d "$path" && "$path" == *.app ]]; then classify_app "$path"
  elif [[ -f "$path" ]]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-identity.XXXXXX")"
    app="$(unpack "$path" "$tmp")" || { rm -rf "$tmp"; return 1; }
    classify_app "$app"; rm -rf "$tmp"
  else die "neither an app nor a zip: $path"; fi
}

designated_pinned() {  # App AND each signed helper/resource bundle: verify signature and exact certificate pin.
  local app="$1" f target identifier expected requirement
  for f in "" "${BINARIES[@]}"; do
    case "$f" in
      ""|MacOS/Vella) identifier=dev.vella.dictation ;;
      MacOS/VellaWorker|MacOS/VellaStreamingWorker) identifier=VellaWorker ;;
      MacOS/VellaModelTool) identifier=VellaModelTool ;;
      Helpers/VellaInstallTool) identifier=VellaInstallTool ;;
      Helpers/vella) identifier=vella ;;
      Resources/mlx-swift_Cmlx.bundle) identifier=org.vella.mlx-swift-Cmlx ;;
      *) return 1 ;;
    esac
    [[ -z "$f" ]] && target="$app" || target="$app/Contents/$f"
    expected="identifier \"$identifier\" and certificate leaf = H\"$(tr '[:upper:]' '[:lower:]' <<<"$PIN_SHA1")\""
    codesign --verify --strict -R "=$expected" "$target" >/dev/null 2>&1 || return 1
    requirement="$(codesign -d -r- "$target" 2>&1 | sed -n 's/^designated => //p')"
    # codesign prints simple helper identifiers without quotes; dotted bundle identifiers keep them.
    requirement="$(sed -E 's/identifier "([^"]+)"/identifier \1/' <<<"$requirement")"
    expected="$(sed -E 's/identifier "([^"]+)"/identifier \1/' <<<"$expected")"
    [[ "$requirement" == "$expected" ]] || return 1
  done
}

for_upload() {
  local path="$1" zip tmp app class
  if [[ -d "$path" && "$path" != *.app ]]; then
    [[ ! -e "$path/$MARKER" ]] || die "refusing $path: it is marked local-only ($MARKER); only the CI-built release may be uploaded"
    local count
    count="$(find "$path" -maxdepth 1 -name 'Vella-*-arm64.zip' ! -name '*-symbols.zip' -print | wc -l | tr -d ' ')"
    [[ "$count" == 1 ]] || die "expected exactly one Vella-*-arm64.zip in $path (found $count)"
    zip="$(find "$path" -maxdepth 1 -name 'Vella-*-arm64.zip' ! -name '*-symbols.zip' -print)"
    [[ -n "$zip" ]] || die "no Vella-*-arm64.zip in $path"
    path="$zip"
  fi
  if [[ -f "$path" ]]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-identity.XXXXXX")"
    app="$(unpack "$path" "$tmp")" || { rm -rf "$tmp"; return 1; }
  else
    app="$path"; tmp=""
  fi
  class="$(classify_app "$app")"
  if [[ "$class" != release ]]; then
    [[ -z "$tmp" ]] || rm -rf "$tmp"
    die "refusing to upload $path: signed as '$class', not 'Vella Release Signing'. Upload only the CI build (a tag runs .github/workflows/release.yml); a locally packaged zip is never uploaded"
  fi
  if ! designated_pinned "$app"; then
    [[ -z "$tmp" ]] || rm -rf "$tmp"
    die "refusing to upload $path: its designated requirement is not the pinned Vella Release Signing certificate"
  fi
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  echo "release-identity: $path is signed by Vella Release Signing with the pinned requirement"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
  classify) [[ $# -eq 2 ]] || die "usage: classify APP|ZIP"; classify_path "$2" ;;
  text-class) [[ $# -eq 2 ]] || die "usage: text-class FILE"; classify_text <"$2" ;;
  mark-local)
    [[ $# -eq 2 && -d "$2" ]] || die "usage: mark-local DIR"
    zip="$(find "$2" -maxdepth 1 -name 'Vella-*-arm64.zip' ! -name '*-symbols.zip' -print | sed -n '1p')"
    [[ -n "$zip" ]] || die "no Vella-*-arm64.zip in $2"
    class="$(classify_path "$zip")"
    if [[ "$class" != release ]]; then
      echo "Signed as '$class', not Vella Release Signing: for local checks only. Never upload this build; release only the CI build (.github/workflows/release.yml)." >"$2/$MARKER"
    fi
    echo "$class" ;;
  for-upload) [[ $# -eq 2 ]] || die "usage: for-upload PATH"; for_upload "$2" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
