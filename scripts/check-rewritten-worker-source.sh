#!/usr/bin/env bash
# Read-only post-filter-repo gate: the public history must retain the measured defaults source and its bytes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$(sed -n 's/^SOURCE=//p' "$ROOT/scripts/worker-source-identity.sh")"
REPO="${1:?usage: check-rewritten-worker-source.sh REWRITTEN_GIT_DIR [REF]}"
REF="${2:-main}"
git -C "$REPO" cat-file -e "$SOURCE^{commit}" || { echo 'rewritten history lost the pinned worker-source commit' >&2; exit 1; }
git -C "$REPO" merge-base --is-ancestor "$SOURCE" "$REF" || { echo 'pinned worker source is not in the publication history' >&2; exit 1; }
git -C "$REPO" diff --exit-code "$SOURCE" "$REF" -- Worker Packages ':(exclude)Worker/**/*.md' >/dev/null \
  || { echo 'rewritten publication Worker/Packages differ from the pinned source' >&2; exit 1; }
echo "rewritten worker source: pinned commit exists, is reachable and matches $REF"
