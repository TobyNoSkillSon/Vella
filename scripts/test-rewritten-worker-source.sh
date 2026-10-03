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
# History-free: an exported tree with no .git, no alternates and none of the historical objects must verify from its
# files alone (CI shallow clone / source export). This is the reviewer's fixture: Worker, Packages and scripts only.
EXPORT="$TMP/export"
mkdir "$EXPORT"
git -C "$ROOT" archive "$CURRENT" Worker Packages scripts | tar -x -C "$EXPORT"
[[ ! -e "$EXPORT/.git" ]] || { echo 'export unexpectedly has .git'; exit 1; }
bash "$EXPORT/scripts/worker-source-identity.sh" >/dev/null || { echo 'history-free export rejected'; exit 1; }
# The same files committed as the sole root of an independent repository: no alternates, no historical Worker object.
git init --quiet "$TMP/solo"
cp -R "$EXPORT/." "$TMP/solo/"
git -C "$TMP/solo" add -A -f
git -C "$TMP/solo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'Fixture sole root'
[[ ! -e "$TMP/solo/.git/objects/info/alternates" ]] || { echo 'solo repository has alternates'; exit 1; }
if git -C "$TMP/solo" cat-file -e 528e719d0956b012f181cdf70cd3baa8f250275f 2>/dev/null; then echo 'historical object unexpectedly present'; exit 1; fi
"$ROOT/scripts/check-rewritten-worker-source.sh" "$TMP/solo" HEAD >/dev/null || { echo 'history-free repository rejected'; exit 1; }
# README.md content is outside the pin (documented rule); any other byte, the README set, and the pinned scripts are not.
variant() { rm -rf "$TMP/variant"; cp -R "$EXPORT" "$TMP/variant"; }
variant; echo 'edited documentation' >>"$TMP/variant/Worker/Sources/MLXAudioSTT/Whisper/README.md"
bash "$TMP/variant/scripts/worker-source-identity.sh" >/dev/null || { echo 'README content edit rejected'; exit 1; }
for change in 'echo x >>Worker/Sources/MLXAudioSTT/Whisper/WhisperAudio.swift' 'echo x >Worker/pin-fixture.swift' \
              'echo x >>Packages/pin-fixture.swift' 'echo x >>scripts/build.sh' 'echo x >Worker/Sources/Stray/README.md' \
              'rm Worker/Sources/MLXAudioSTT/Parakeet/README.md' 'chmod +x Worker/Package.swift' 'rm -r Worker'; do
  variant
  (cd "$TMP/variant" && mkdir -p Worker/Sources/Stray && eval "$change") 2>/dev/null || true
  if bash "$TMP/variant/scripts/worker-source-identity.sh" >/dev/null 2>&1; then echo "history-free: $change accepted"; exit 1; fi
done
echo 'rewritten source regression: present/missing/history-independent root/history-free export and repository/README rule/Worker/Packages/build mismatch pass'
