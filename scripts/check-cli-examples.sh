#!/usr/bin/env bash
# All documented fenced vella commands run through the real CLI using an isolated fixture transport.
# DocCLIExamplesTests also checks literal output examples against the actual formatters.
set -euo pipefail
cd "$(dirname "$0")/.."
# This suite is part of scripts/test-unit.sh; use XCTest's real host, not a zero-test SwiftPM launcher.
BIN="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools /Library/Developer/CommandLineTools/usr/bin/swift build --build-system native --show-bin-path)"
DEVELOPER_DIR="${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun xctest -XCTest VellaAppTests.DocCLIExamplesTests "$BIN/VellaPackageTests.xctest"
