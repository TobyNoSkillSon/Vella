#!/bin/bash
# Unit tests of the Worker package (CPU only; no kernel runs, no model loads).
# They build with the Command Line Tools Swift, the toolchain the helpers ship with: binaries from Xcode 27's Swift 6.4
# reference `_swift_initBorrow`, which macOS 26 lacks, so its test bundle cannot load. The Command Line Tools carry
# swift-testing (not XCTest) in Library/Developer/Frameworks, which SwiftPM's native build system does not search.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" test --package-path Worker --build-system native \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" "$@"
