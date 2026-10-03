#!/usr/bin/env bash
# App/core and wire XCTest suites: compile with shipping CLT Swift, run with Xcode's XCTest host.
# CLT lacks XCTest and the SDK PlatformPath required by SwiftPM's XCTest launcher.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
XCODE="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PLATFORM="$XCODE/Platforms/MacOSX.platform/Developer"
PACKAGE=.
if [[ $# != 0 ]]; then
  [[ $# == 2 && $1 == --package-path ]] || { echo 'usage: test-unit.sh [--package-path PATH]'; exit 2; }
  PACKAGE="$2"
fi
LOG="$(mktemp -t vella-unit-tests)"
trap 'rm -f "$LOG"' EXIT
# Build the bundle without SwiftPM's launcher (which cannot use the CLT SDK).
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" test --package-path "$PACKAGE" --build-system native --disable-swift-testing \
  -Xswiftc -F -Xswiftc "$PLATFORM/Library/Frameworks" \
  -Xswiftc -I -Xswiftc "$PLATFORM/usr/lib" \
  -Xlinker -F -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -L -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib"
BIN="$(DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" build --package-path "$PACKAGE" --build-system native --show-bin-path)"
BUNDLES=()
while IFS= read -r bundle; do BUNDLES+=("$bundle"); done < <(find "$BIN" -maxdepth 1 -name '*PackageTests.xctest')
[[ ${#BUNDLES[@]} == 1 ]] || { echo 'Expected exactly one XCTest bundle'; exit 1; }
DEVELOPER_DIR="$XCODE" xcrun xctest "${BUNDLES[0]}" 2>&1 | tee "$LOG"
grep -Eq 'Executed [1-9][0-9]* tests?' "$LOG" || { echo 'No XCTest tests executed'; exit 1; }
