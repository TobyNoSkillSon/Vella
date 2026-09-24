#!/bin/bash
# Create the optional, pinned source-build fallback from committed public files.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: package-native-source.sh <version> <output-dir>' >&2; exit 2; }
VERSION="$1" OUT="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -d "$OUT" ]] || { echo 'Invalid version or output directory.' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo 'Commit and review the source tree before packaging.' >&2; exit 1; }
ASSET="Vella-$VERSION-source.tar.gz"
git -C "$ROOT" archive --format=tar --prefix="Vella-$VERSION/" HEAD | gzip -n > "$OUT/$ASSET"
echo "$OUT/$ASSET"
