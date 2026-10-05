#!/usr/bin/env bash
# Run locally what .github/workflows/ci.yml and release.yml check, without GitHub Actions.
# Builds, tests and packages; installs, uploads, tags and publishes nothing.
#
#   scripts/release-check.sh            full local check: integration tests included, package signed ad hoc (as CI)
#   scripts/release-check.sh --ci       unit tests only (CI=true), exactly the CI test set
#   scripts/release-check.sh --signed   sign with "Vella Release Signing" (must be in the login keychain) and check
#                                       the designated requirement and every binary's authority, as release.yml does
#
# Steps: tracked files are source only; toolchains (Command Line Tools Swift 6.3.3 or 6.4, Metal Toolchain); the version has
# a CHANGELOG section (the release notes); relative links in the public docs resolve; scripts/lint.sh (swift-format
# layout and SwiftLint rules on first-party code); scripts/package-release.sh
# (build, helper smoke tests, zip checks) into a temporary directory; SHA256SUMS verifies; xcrun swift test;
# scripts/test-worker.sh (the Worker package's unit tests); the VellaWire package's tests.
# One line per step; each step's full output is in the log directory printed at the start.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT"
CLT_SWIFT=/Library/Developer/CommandLineTools/usr/bin/swift
VELLA_SIGNING_SHA1=2CA2587C8B85EF687E68950E405EC58CE31FC1C7   # same pin as release.yml
MODE=local SIGNED=0
for a in "$@"; do
  case "$a" in
    --ci) MODE=ci ;;
    --signed) SIGNED=1 ;;
    --step-fixture|--selftest-step) MODE="$a" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $a; see $0 --help" >&2; exit 2 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
WORK="$PROJECT/.build/release-check/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORK"
echo "release-check $VERSION ($MODE$([[ $SIGNED == 1 ]] && echo ', signed')) · log $WORK"

step() {  # step NAME FUNCTION: run, log, print one line; stop on the first failure
  local name="$1"; shift
  local log="$WORK/$(tr -c 'A-Za-z0-9.\n' '-' <<<"$name").log" start=$SECONDS
  # A function invoked as an if condition inherits errexit suppression, even in a subshell.
  # Run the body as a standalone subshell with its own errexit, then inspect its status.
  set +e
  ( set -euo pipefail; "$@" ) >"$log" 2>&1
  local result=$?
  set -e
  if [[ $result == 0 ]]; then
    echo "ok    $name ($((SECONDS - start)) s)"
  else
    echo "FAIL  $name ($((SECONDS - start)) s): $(grep -v '^[[:space:]]*$' "$log" | tail -1)"
    echo "      full output: $log"
    exit 1
  fi
}

source_only() {
  if git ls-files | grep -E '^(lab|dist|dist-preview|logs|Marketing|\.build)/|\.py$'; then
    echo "local-only files are tracked (lab/, dist/, logs/, Marketing/, .build/ or Python)"; return 1
  fi
}

no_lab_paths() {
  local listing="$1"
  if grep -E '(^|/)lab(/|$)' "$listing"; then
    echo "release tree contains a local-only lab/ path"; return 1
  fi
}

source_archive_no_lab() {
  git archive --format=tar HEAD | tar -tf - >"$WORK/source-archive-paths.txt"
  no_lab_paths "$WORK/source-archive-paths.txt"
}

release_archive_no_lab() {
  local tree="$WORK/release-tree-check"
  zipinfo -1 "$WORK/release/Vella-$VERSION-arm64.zip" >"$WORK/release-archive-paths.txt"
  no_lab_paths "$WORK/release-archive-paths.txt" || return 1
  mkdir -p "$tree"
  /usr/bin/unzip -q "$WORK/release/Vella-$VERSION-arm64.zip" -d "$tree"
  (cd "$tree" && find . -print) >"$WORK/release-tree-paths.txt"
  no_lab_paths "$WORK/release-tree-paths.txt"
}

toolchains() {
  local v; v="$("$CLT_SWIFT" --version 2>&1)"; echo "$v"
  # Release artifacts are built in CI with 6.3.3 (release.yml enforces it); local checks also accept 6.4, whose builds
  # Worker/build-split.sh weak-links for macOS 26.
  grep -E 'Apple Swift version (6\.3\.3|6\.4(\.[0-9]+)?) ' <<<"$v" >/dev/null \
    || { echo "needs Command Line Tools Swift 6.3.3 (as releases) or 6.4 (xcode-select --install)"; return 1; }
  DEVELOPER_DIR="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcodebuild -version
  DEVELOPER_DIR="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcodebuild -showComponent MetalToolchain 2>/dev/null | grep 'Status: installed' >/dev/null \
    || { echo "Metal Toolchain missing: xcodebuild -downloadComponent MetalToolchain"; return 1; }
  DEVELOPER_DIR="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun metal --version
}

changelog() {  # release.yml puts this section into the draft release notes
  local notes; notes="$(awk -v v="$VERSION" '$0 ~ "^## " v "( |$)" {on=1; next} on && /^## / {exit} on' CHANGELOG.md)"
  grep -q "[^[:space:]]" <<<"$notes" || { echo "CHANGELOG.md has no section '## $VERSION'"; return 1; }
  printf '%s\n' "$notes"
}

doc_links() {  # relative markdown links and image sources in the public docs point at files that exist
  local bad=0 doc target
  for doc in README.md AGENTS.md CONTRIBUTING.md SECURITY.md CHANGELOG.md docs/USAGE.md Resources/SKILL.md; do
    while IFS= read -r target; do
      target="${target%%#*}"
      [[ -z "$target" || "$target" =~ ^(https?|mailto): ]] && continue
      [[ -e "$(dirname "$doc")/$target" ]] || { echo "$doc: missing $target"; bad=1; }
    done < <(grep -oE '\]\([^)]+\)|<img src="[^"]+"' "$doc" | sed -E 's/^\]\(//; s/\)$//; s/^<img src="//; s/"$//')
  done
  return $bad
}

package() {
  local identity="${VELLA_SIGN_IDENTITY:--}"
  if [[ $SIGNED == 1 ]]; then
    security find-identity -p codesigning | grep "$VELLA_SIGNING_SHA1" >/dev/null \
      || { echo "Vella Release Signing ($VELLA_SIGNING_SHA1) is not in the keychain"; return 1; }
    identity=$VELLA_SIGNING_SHA1
  fi
  DEVELOPER_DIR="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    VELLA_SIGN_IDENTITY="$identity" VELLA_RELEASE_OUTPUT_DIR="$WORK/release" scripts/package-release.sh "$VERSION" || return
  cat Worker/.build/split-build-provenance.txt
}

# A development-signed (or ad hoc) zip exists for these local checks only: it is marked local-only and refused for
# upload. Only a zip signed by Vella Release Signing with the pinned requirement passes `for-upload`.
upload_identity_guard() {
  local class
  class="$(scripts/release-identity.sh mark-local "$WORK/release")"
  echo "signed as: $class"
  if [[ $class == release ]]; then
    scripts/release-identity.sh for-upload "$WORK/release"
  else
    [[ -e "$WORK/release/LOCAL-ONLY-NOT-FOR-UPLOAD.txt" ]] || { echo "a $class-signed package is not marked local-only"; return 1; }
    if scripts/release-identity.sh for-upload "$WORK/release"; then echo "a $class-signed package was accepted for upload"; return 1; fi
    echo "refused for upload, as required: only the CI build (Vella Release Signing) may be uploaded"
  fi
  [[ $SIGNED == 0 || $class == release ]] || { echo "--signed must produce a release-signed package"; return 1; }
}

checksums() { (cd "$WORK/release" && shasum -a 256 -c SHA256SUMS); }

signature() {  # release.yml "Check the signature in the zip"
  local check="$WORK/signature-check" app pin expected requirement f
  rm -rf "$check" && mkdir -p "$check"
  /usr/bin/unzip -q "$WORK/release/Vella-$VERSION-arm64.zip" -d "$check"
  app="$check/Vella.app"
  [[ "$(readlink "$app/Contents/MacOS/VellaStreamingWorker")" == VellaWorker ]] || { echo 'Invalid streaming alias target'; return 1; }
  codesign --verify --deep --strict "$app"
  pin="$(tr '[:upper:]' '[:lower:]' <<<"$VELLA_SIGNING_SHA1")"
  expected="identifier \"dev.vella.dictation\" and certificate leaf = H\"$pin\""
  requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
  [[ "$requirement" == "$expected" ]] || { echo "designated requirement is '$requirement', expected '$expected'"; return 1; }
  for f in MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella \
           Resources/mlx-swift_Cmlx.bundle; do
    codesign -dvv "$app/Contents/$f" 2>&1 | grep -x 'Authority=Vella Release Signing' >/dev/null || { echo "$f is not signed by Vella Release Signing"; return 1; }
  done
}

tests() {
  if [[ $MODE == ci ]]; then CI=true NSUnbufferedIO=YES scripts/test-unit.sh; else NSUnbufferedIO=YES scripts/test-unit.sh; fi
}

if [[ $MODE == --step-fixture ]]; then
  case "${VELLA_STEP_FIXTURE:?}" in
    archive)
      zipinfo() { printf '%s\n' 'Vella.app/Contents/MacOS/Vella'; }
      mkdir -p "$WORK/release"
      echo 'planted invalid zip' >"$WORK/release/Vella-$VERSION-arm64.zip"
      step "archive fixture" release_archive_no_lab ;;
    signature)
      mkdir -p "$WORK/fixture/Vella.app/Contents/MacOS" "$WORK/release"
      ln -s VellaWorker "$WORK/fixture/Vella.app/Contents/MacOS/VellaStreamingWorker"
      (cd "$WORK/fixture" && /usr/bin/zip -qry "$WORK/release/Vella-$VERSION-arm64.zip" Vella.app)
      codesign() {
        if [[ $1 == --verify ]]; then echo 'planted codesign verify failure'; return 72; fi
        echo 'designated => identifier "dev.vella.dictation" and certificate leaf = H"2ca2587c8b85ef687e68950e405ec58ce31fc1c7"'
        echo 'Authority=Vella Release Signing'
      }
      step "signature fixture" signature ;;
  esac
  echo 'ERROR: planted failure passed'; exit 1
fi
if [[ $MODE == --selftest-step ]]; then
  for fixture in archive signature; do
    output="$(VELLA_STEP_FIXTURE="$fixture" "$0" --step-fixture 2>&1)" && { echo "$fixture failure was accepted"; exit 1; }
    grep -q "FAIL  $fixture fixture" <<<"$output" || { echo "$output"; exit 1; }
    if grep -q '^ok ' <<<"$output"; then echo "$output"; exit 1; fi
  done
  echo 'release step selftest: unzip and codesign verification fail closed'; exit 0
fi

step "release step planted failures" "$0" --selftest-step
step "detached pipefail identity checks" scripts/test-pipefail.sh
step "source only in git" source_only
step "source archive excludes lab" source_archive_no_lab
step "published-history commit citations" xcrun swift scripts/check-commit-citations.swift
step "commit citation guard fixture" xcrun swift scripts/check-commit-citations.swift --selftest
step "diagnose reference guard fixture" xcrun swift scripts/check-diagnose-reference.swift --selftest
step "qualified diagnose reference" xcrun swift scripts/check-diagnose-reference.swift
step "shipped defaults worker-source receipt" scripts/worker-source-identity.sh
step "public data privacy" xcrun swift scripts/public-data-guard.swift
step "toolchains" toolchains
step "changelog $VERSION" changelog
step "doc links" doc_links
step "public prose claims" scripts/check-doc-claims.sh
step "public prose claims fixture" scripts/check-doc-claims.sh --selftest
step "release identity fixture" scripts/test-release-identity.sh
step "model READMEs match the benchmarks" xcrun swift scripts/model-readmes.swift --check
step "benchmark methods match published inputs" xcrun swift scripts/benchmark-method.swift --check
step "skill and user guide model lists" xcrun swift scripts/agent-docs.swift --check
step "lint (swift-format, SwiftLint)" scripts/lint.sh
step "symbol retention fixture" scripts/test-release-symbols.sh
step "build and package" package
step "release archive and tree exclude lab" release_archive_no_lab
step "SHA256SUMS" checksums
step "release identity (nothing development-signed is uploadable)" upload_identity_guard
if [[ $SIGNED == 1 ]]; then step "release signature" signature; fi
step "swift test ($([[ $MODE == ci ]] && echo unit || echo 'unit and integration'))" tests
step "documented CLI examples" scripts/check-cli-examples.sh
step "worker unit tests" scripts/test-worker.sh
step "VellaWire tests" scripts/test-unit.sh --package-path Packages/VellaWire

ZIP="$WORK/release/Vella-$VERSION-arm64.zip"
echo "passed: $ZIP · sha256 $(awk -v name="$(basename "$ZIP")" '$2 == name {print $1}' "$WORK/release/SHA256SUMS") · $(du -h "$ZIP" | cut -f1 | xargs)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || echo "note: uncommitted changes to tracked files; a tag builds only what is committed"
