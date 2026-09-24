#!/bin/sh
# CPU-only checks: no model loads, GPU operations, downloads, or Python.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sdk=$(xcrun --show-sdk-path)
for kind in Validation System Wire; do
    case "$kind" in
        Validation) set -- "$root/Sources/VellaWorker/Validation.swift" ;;
        System) set -- "$root/Sources/VellaWorker/System.swift" ;;
        Wire) set -- "$root/Sources/VellaWorker/Validation.swift" "$root/Sources/VellaWorker/Wire.swift" ;;
    esac
    xcrun swiftc -sdk "$sdk" -target arm64-apple-macosx14.0 "$@" "$root/QA/${kind}Checks.swift" -o "$tmp/check"
    sandbox-exec -p '(version 1)(allow default)(deny network*)' "$tmp/check"
done
