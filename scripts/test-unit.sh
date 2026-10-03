#!/usr/bin/env bash
# App/core and wire unit tests: shipping CLT Swift, with Xcode's XCTest headers/support.
# Xcode 27's Swift emits runtime symbols macOS 26 cannot load; CLT does not ship XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
XCODE="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PLATFORM="$XCODE/Platforms/MacOSX.platform/Developer"
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" test --build-system native \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xswiftc -F -Xswiftc "$PLATFORM/Library/Frameworks" \
  -Xswiftc -I -Xswiftc "$PLATFORM/usr/lib" \
  -Xlinker -F -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -L -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" "$@"
