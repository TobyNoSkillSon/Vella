#!/usr/bin/env bash
# Content identity survives author/message/blob rewrites outside the pinned paths.
set -euo pipefail
SOURCE=08203e24ebdf83004ca4d81daa03f678880898c2 # informational measured-defaults commit, never a reachability gate
BASE_WORKER_TREE=528e719d0956b012f181cdf70cd3baa8f250275f
WORKER_TREE=af976137fbcd3cb0346fb187aced20cd82f9cc86
PACKAGES_TREE=093375e515b30db74a5803abfdd6c1c0d28e29e2
# Exhaustive documentation-only delta from 08203e2; Worker/Package.swift excludes this README from its target.
WORKER_DOC_CHANGES="Sources/MLXAudioSTT/NemotronASR/README.md
Sources/MLXAudioSTT/Parakeet/README.md
Sources/MLXAudioSTT/Qwen3ASR/README.md
Sources/MLXAudioSTT/Whisper/README.md"
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

verify_source_trees() {
  local repo="$1" ref="$2" actual path changes hash
  [[ "$(git -C "$repo" rev-parse "$ref:Worker")" == "$WORKER_TREE" ]] || { echo 'Worker tree differs from pinned source' >&2; return 1; }
  [[ "$(git -C "$repo" rev-parse "$ref:Packages")" == "$PACKAGES_TREE" ]] || { echo 'Packages tree differs from measured source' >&2; return 1; }
  changes="$(git -C "$repo" diff --name-only "$BASE_WORKER_TREE" "$WORKER_TREE")"
  [[ "$changes" == "$WORKER_DOC_CHANGES" ]] || { echo 'Worker documentation delta differs from its exhaustive receipt' >&2; return 1; }
  while IFS= read -r path; do
    [[ "${path##*/}" == README.md ]] || { echo 'Worker code changed from measured defaults' >&2; return 1; }
    git -C "$repo" show "$ref:Worker/Package.swift" | grep -Fq "\"${path#Sources/MLXAudioSTT/}\"" || return 1
  done <<<"$changes"
  actual="$(for path in "${build_paths[@]}"; do
    hash="$(git -C "$repo" show "$ref:$path" | shasum -a 256 | awk '{print $1}')" || return 1
    printf '%s  %s\n' "$hash" "$path"
  done | shasum -a 256 | awk '{print $1}')"
  [[ "$actual" == "$BUILD_EXPECTED" ]] || { echo 'pinned build scripts changed' >&2; return 1; }
  echo "worker source trees: Worker=$WORKER_TREE Packages=$PACKAGES_TREE; code byte-identical to measured defaults; documentation delta: $changes; build scripts=$BUILD_EXPECTED"
}
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
cd "$(dirname "$0")/.."
verify_source_trees "$PWD" HEAD
# Compare an ephemeral index of working bytes too; do not mutate the user's index.
index="$(mktemp /tmp/vella-source-index.XXXXXX)"; rm "$index"
trap 'rm -f "$index"' EXIT
GIT_INDEX_FILE="$index" git read-tree HEAD
GIT_INDEX_FILE="$index" git add -- Worker Packages "${build_paths[@]}"
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
verify_source_trees "$PWD" "$tree"
