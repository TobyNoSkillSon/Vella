#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/vella-rewritten-source.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --bare --shared "$ROOT" "$TMP/good.git"
# Include current working source pin/documentation (the caller may be checking before committing).
INDEX="$TMP/current-index"
GIT_INDEX_FILE="$INDEX" git -C "$ROOT" read-tree HEAD
GIT_INDEX_FILE="$INDEX" git -C "$ROOT" add -- Worker Packages scripts
TREE="$(GIT_INDEX_FILE="$INDEX" git -C "$ROOT" write-tree)"
CURRENT="$(echo 'Fixture current source' | git -C "$ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE" -p HEAD)"
git -C "$TMP/good.git" update-ref HEAD "$CURRENT"
"$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" HEAD
# A missing source must fail closed.
git init --quiet --bare "$TMP/missing.git"
if "$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/missing.git" HEAD >/dev/null 2>&1; then echo 'missing source accepted'; exit 1; fi
# A history rewrite/root with identical trees must pass without the original commit being reachable.
TREE="$(git -C "$TMP/good.git" rev-parse 'HEAD^{tree}')"
ORPHAN="$(echo 'Fixture unrelated root' | git -C "$TMP/good.git" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE")"
git -C "$TMP/good.git" update-ref refs/heads/orphan "$ORPHAN"
"$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" orphan
# Exact identity refuses changes to Worker code, Packages code and pinned build scripts.
INDEX="$TMP/index"
for changed in Worker/pin-fixture.swift Packages/pin-fixture.swift scripts/build.sh; do
  rm -f "$INDEX"
  GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" read-tree HEAD
  BLOB="$(echo 'wrong source fixture' | git -C "$TMP/good.git" hash-object -w --stdin)"
  GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" update-index --add --cacheinfo "100644,$BLOB,$changed"
  TREE="$(GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" write-tree)"
  BAD="$(echo 'Fixture source mismatch' | git -C "$TMP/good.git" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE" -p HEAD)"
  git -C "$TMP/good.git" update-ref refs/heads/bad "$BAD"
  if "$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" bad >/dev/null 2>&1; then echo "$changed mismatch accepted"; exit 1; fi
done
echo 'rewritten source regression: present/missing/history-independent root/Worker/Packages/build mismatch pass'
