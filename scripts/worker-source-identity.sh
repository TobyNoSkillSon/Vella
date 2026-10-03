#!/usr/bin/env bash
# Release 2.0 defaults-source receipt. The historical measured-source bridge is retained separately.
# Worker/Packages must match the named defaults commit; build scripts keep their measured byte pin.
set -euo pipefail
cd "$(dirname "$0")/.."
untracked="$(git ls-files --others --exclude-standard Worker Packages | grep -v '\.md$' || true)"
[[ -z "$untracked" ]] || { echo "untracked worker source outside bridge: $untracked"; exit 1; }
# Immutable defaults source commit; measurement provenance remains 55cb080/40a2eef in the historical bridge.
SOURCE=08203e24ebdf83004ca4d81daa03f678880898c2
git cat-file -e "$SOURCE^{commit}" || { echo "defaults source commit is missing: $SOURCE"; exit 1; }
git diff --exit-code "$SOURCE" HEAD -- Worker Packages ':(exclude)Worker/**/*.md' >/dev/null \
  || { echo "Worker/Packages differ from defaults source $SOURCE"; exit 1; }
git diff --exit-code "$SOURCE" -- Worker Packages ':(exclude)Worker/**/*.md' >/dev/null \
  || { echo "working Worker/Packages differ from defaults source $SOURCE"; exit 1; }
echo "worker source matches defaults commit $SOURCE (measured keys checked separately)"

# The bridge also depends on the packaging/toolchain path, not only Worker/Packages.
build_paths=(
  scripts/build.sh
  scripts/check-helpers.swift
  scripts/icon.swift
  scripts/package-release.sh
  scripts/prepare-build.swift
  scripts/release-zip.sh
  scripts/strip-release.sh
  scripts/test-worker.sh
  scripts/verify-release-symbols.sh
)
BUILD_EXPECTED=a4a1fbcbdec5ecc7ade7ea8bf0b241cc5fec78a1e368aa1b2d3b5f7c9db463b1
build_actual="$(printf '%s\n' "${build_paths[@]}" | while IFS= read -r path; do shasum -a 256 "$path"; done | shasum -a 256 | awk '{print $1}')"
[[ "$build_actual" == "$BUILD_EXPECTED" ]] || { echo "build scripts differ from shipped bridge 40a2eef: $build_actual"; exit 1; }
echo "build scripts match 40a2eef: $build_actual"
