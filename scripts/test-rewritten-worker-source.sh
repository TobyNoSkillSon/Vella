#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/vella-rewritten-source.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --bare --shared "$ROOT" "$TMP/good.git"
"$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" HEAD
# A missing source must fail closed.
git init --quiet --bare "$TMP/missing.git"
if "$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/missing.git" HEAD >/dev/null 2>&1; then echo 'missing source accepted'; exit 1; fi
# Present but unreachable source must fail too.
TREE="$(git -C "$TMP/good.git" rev-parse 'HEAD^{tree}')"
ORPHAN="$(echo 'Fixture unrelated root' | git -C "$TMP/good.git" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE")"
git -C "$TMP/good.git" update-ref refs/heads/orphan "$ORPHAN"
if "$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" orphan >/dev/null 2>&1; then echo 'unreachable source accepted'; exit 1; fi
# Reachable source with altered worker bytes must fail.
INDEX="$TMP/index"
GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" read-tree HEAD
BLOB="$(echo 'wrong worker fixture' | git -C "$TMP/good.git" hash-object -w --stdin)"
GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" update-index --add --cacheinfo "100644,$BLOB,Worker/pin-fixture.swift"
TREE="$(GIT_INDEX_FILE="$INDEX" git -C "$TMP/good.git" write-tree)"
BAD="$(echo 'Fixture worker mismatch' | git -C "$TMP/good.git" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE" -p HEAD)"
git -C "$TMP/good.git" update-ref refs/heads/bad "$BAD"
if "$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/good.git" bad >/dev/null 2>&1; then echo 'worker mismatch accepted'; exit 1; fi
echo 'rewritten source regression: present/missing/unreachable/mismatch pass'
