#!/usr/bin/env bash
# Release 2.0 measured-source bridge. Markdown is generated documentation, not executed worker source.
# Pin every other tracked Worker/Packages file and the measured build scripts by bytes; works with shallow Git history.
set -euo pipefail
cd "$(dirname "$0")/.."
untracked="$(git ls-files --others --exclude-standard Worker Packages | grep -v '\.md$' || true)"
[[ -z "$untracked" ]] || { echo "untracked worker source outside bridge: $untracked"; exit 1; }
EXPECTED=1bdd71a270f7cf09d66629ef7a25e50806428029adaf5ab232c23737a58d595d
actual="$(git ls-files Worker Packages | grep -v '\.md$' | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done | shasum -a 256 | awk '{print $1}')"
[[ "$actual" == "$EXPECTED" ]] || { echo "worker source differs from shipped bridge 40a2eef: $actual"; exit 1; }
echo "worker source matches 40a2eef (generated Markdown excluded): $actual"

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
