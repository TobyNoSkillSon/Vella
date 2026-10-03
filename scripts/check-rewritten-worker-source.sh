#!/usr/bin/env bash
# Read-only post-rewrite gate: commit identities are informational; pinned trees/build bytes are authoritative.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/worker-source-identity.sh"
verify_source_trees "${1:?usage: check-rewritten-worker-source.sh REWRITTEN_GIT_DIR [REF]}" "${2:-main}"
