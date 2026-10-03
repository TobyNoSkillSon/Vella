#!/usr/bin/env bash
# App/core and wire unit tests: shipping CLT Swift, with Xcode's XCTest headers/support.
# Xcode 27's Swift emits runtime symbols macOS 26 cannot load; CLT does not ship XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
XCODE="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PLATFORM="$XCODE/Platforms/MacOSX.platform/Developer"
LOG="$(mktemp -t vella-unit-tests)"
trap 'rm -f "$LOG"' EXIT
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" test --build-system native --enable-xctest --disable-swift-testing \
  -Xswiftc -F -Xswiftc "$PLATFORM/Library/Frameworks" \
  -Xswiftc -I -Xswiftc "$PLATFORM/usr/lib" \
  -Xlinker -F -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -L -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" "$@" | tee "$LOG"
# CLT's default can build an XCTest bundle without running it; an empty run is not a pass.
grep -Eq 'Executed [1-9][0-9]* tests?' "$LOG" || { echo 'No XCTest tests executed'; exit 1; }
