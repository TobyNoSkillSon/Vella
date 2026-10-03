#!/usr/bin/env bash
# Content identity survives author/message/blob rewrites outside the pinned paths, and needs no git history at all:
# the gate recomputes git tree hashes from the files it is given (a git ref, or a plain directory such as a CI shallow
# clone or an exported tree with no .git) and compares them with the pins below.
#
# README rule: every README.md under Worker/ is omitted before the Worker tree is hashed. Worker/Package.swift
# excludes the four target-source READMEs from the build, and Worker/README.md is outside Sources, so README content
# never reaches a binary and is not pinned. Which README.md files may exist is pinned (the set below); everything else
# under Worker/ is pinned byte for byte (content and exec bit), and so is all of Packages/.
set -euo pipefail
SOURCE=843a43444659dbd7f2de507b1e2da11453efb31b # informational measured-defaults commit, never a reachability gate
WORKER_CODE_TREE=98378da5eaf576d46a677917e1f4dc26cd20bc72   # git tree of Worker/ with its README.md files removed
PACKAGES_TREE=6851d8c101f507aea8980af93fd877aa0e84a20c
# 3 Oct chip-safety delta: macOS 26.2 tensor preflight; GPU architecture/name in gate keys and optional verdict metadata.
# Kernels, tile plans, deadlines, dependency pins and pinned build scripts are unchanged.
# Full Worker tree including README.md files, as recorded in Resources/benchmarks.json builds.shipped.worker_source_trees.
# Reported, never gated: README content is outside the pin.
WORKER_FULL_TREE=3b5e11b6f7335eafe03f7dacb6c30b897e10a592
# Recorded provenance, not a gate on history: the documentation-only delta from the measured Worker tree of 843a434
# (BASE_WORKER_TREE, full tree including READMEs). The history scrub of 3 Oct rewrote that commit's Whisper README, so this
# is the rewritten tree; the pre-scrub tree survives only in the local backup (see its receipt). Package.swift excludes each of
# these from its target. They are the only README.md files besides Worker/README.md that may exist; verified against the
# files, never against history.
BASE_WORKER_TREE=53e0cd3fce3cb0b11646dd3b085c0328e51fc5aa
WORKER_DOC_CHANGES="Sources/MLXAudioSTT/NemotronASR/README.md
Sources/MLXAudioSTT/Parakeet/README.md
Sources/MLXAudioSTT/Qwen3ASR/README.md
Sources/MLXAudioSTT/Whisper/README.md"
# The bridge also depends on the packaging/toolchain path, not only Worker/Packages.
# 3 Oct: package-release adds a metadata-only reference qualification guard; build/inference paths are unchanged.
build_paths=(
  scripts/build.sh
  scripts/check-helpers.swift
  scripts/check-diagnose-reference.swift
  scripts/icon.swift
  scripts/package-release.sh
  scripts/prepare-build.swift
  scripts/release-zip.sh
  scripts/strip-release.sh
  scripts/test-worker.sh
  scripts/verify-release-symbols.sh
)
BUILD_EXPECTED=1862cec695156417ab3518e58b95ab61f491f8c59e867c4709ee68c9024dfc90

# git with the user's configuration (autocrlf, excludes, hooks) out of the hash.
g() { git -c core.autocrlf=false -c core.excludesFile=/dev/null "$@"; }

# Verify the pins against the index in $GIT_INDEX_FILE (GIT_DIR/GIT_WORK_TREE already set by the caller).
verify_index() {
  local tree actual path hash readmes expected full
  readmes="$(g ls-files -- Worker | grep -E '(^|/)README\.md$' | LC_ALL=C sort || true)"
  expected="$({ echo Worker/README.md; while IFS= read -r path; do echo "Worker/$path"; done <<<"$WORKER_DOC_CHANGES"; } | LC_ALL=C sort)"
  [[ "$readmes" == "$expected" ]] || { echo 'Worker README.md files differ from the recorded documentation list' >&2; return 1; }
  while IFS= read -r path; do
    [[ "${path##*/}" == README.md ]] || return 1
    g cat-file blob ":Worker/Package.swift" | grep -Fq "\"${path#Sources/MLXAudioSTT/}\"" || { echo "Worker/Package.swift does not exclude $path" >&2; return 1; }
  done <<<"$WORKER_DOC_CHANGES"
  tree="$(g write-tree)" || return 1
  [[ "$(g rev-parse "$tree:Worker")" == "$WORKER_FULL_TREE" ]] && full=identical || full='differs in README.md content only (not gated)'
  echo "worker source: published full Worker tree (README.md included) $full"
  while IFS= read -r path; do g update-index --force-remove -- "$path" || return 1; done <<<"$readmes"
  tree="$(g write-tree)" || return 1
  [[ "$(g rev-parse "$tree:Worker")" == "$WORKER_CODE_TREE" ]] || { echo 'Worker code differs from the pinned source (README.md files excluded)' >&2; return 1; }
  [[ "$(g rev-parse "$tree:Packages")" == "$PACKAGES_TREE" ]] || { echo 'Packages tree differs from measured source' >&2; return 1; }
  actual="$(for path in "${build_paths[@]}"; do
    hash="$(g cat-file blob ":$path" | shasum -a 256 | awk '{print $1}')" || return 1
    printf '%s  %s\n' "$hash" "$path"
  done | shasum -a 256 | awk '{print $1}')"
  [[ "$actual" == "$BUILD_EXPECTED" ]] || { echo 'pinned build scripts changed' >&2; return 1; }
}

# Run verify_index on a throw-away repository so neither the caller's index nor its object store is touched.
# verify_source_trees REPO REF: the tree of REF in REPO (only that tree's objects are read).
# verify_source_dir DIR: the files in DIR as they are on disk (no .git needed; ignore rules are not applied, only
# .build/.swiftpm/.DS_Store artifacts are skipped).
_verify_isolated() {
  local mode="$1" src="$2" ref="${3:-}" scratch rc=0 note="" tree="" objects=""
  if [[ "$mode" == ref ]]; then # resolve before GIT_DIR is redirected
    tree="$(git -C "$src" rev-parse --verify "$ref^{tree}")" || return 1
    objects="$(git -C "$src" rev-parse --path-format=absolute --git-path objects)" || return 1
  fi
  scratch="$(mktemp -d /tmp/vella-source-verify.XXXXXX)"
  mkdir "$scratch/empty"
  git init --quiet --bare "$scratch/gd"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_DIR="$scratch/gd" GIT_INDEX_FILE="$scratch/index"
    if [[ "$mode" == ref ]]; then
      export GIT_WORK_TREE="$scratch/empty" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects"
      g read-tree "$tree" || exit 1
    else
      export GIT_WORK_TREE="$src"
      # -f: root ignore rules (*.wav) cover tracked fixtures that a plain export contains. SwiftPM/Finder artifacts are
      # never source, so they are pruned by name (a source checkout that has been built carries them).
      g add -A -f -- Worker Packages "${build_paths[@]}" ':(exclude,glob)**/.build/**' ':(exclude,glob)**/.swiftpm/**' ':(exclude,glob)**/.DS_Store' || exit 1
    fi
    verify_index
  ) || rc=$?
  if [[ $rc -eq 0 ]]; then
    if [[ "$mode" == ref ]] && git -C "$src" cat-file -e "$BASE_WORKER_TREE^{tree}" 2>/dev/null; then
      note="; history present: $(git -C "$src" diff --name-only "$BASE_WORKER_TREE" "$tree:Worker" | { grep -vc 'README\.md$' || true; }) non-README paths differ from the measured Worker tree"
    fi
    echo "worker source: Worker code tree (README.md excluded)=$WORKER_CODE_TREE Packages=$PACKAGES_TREE; build scripts=$BUILD_EXPECTED; recorded documentation delta: $(echo $WORKER_DOC_CHANGES)$note"
  fi
  rm -rf "$scratch"
  return $rc
}
verify_source_trees() { _verify_isolated ref "$1" "$2"; }
verify_source_dir() { _verify_isolated dir "$1"; }
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
cd "$(dirname "$0")/.."
# Committed bytes (when this is a repository, shallow or not), then the bytes on disk; a tree with no .git gets the second.
if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse --verify --quiet 'HEAD^{tree}' >/dev/null; then verify_source_trees "$PWD" HEAD; fi
verify_source_dir "$PWD"
