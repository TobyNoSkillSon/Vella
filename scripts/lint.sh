#!/usr/bin/env bash
# Lint first-party Swift: swift-format (layout, .swift-format) and SwiftLint (rules, .swiftlint.yml).
#   scripts/lint.sh          check; exits nonzero on any finding (release-check runs this)
#   scripts/lint.sh --fix    reformat in place with swift-format, then check
# Uses the Command Line Tools swift-format (the release toolchain) and SwiftLint 0.65 (brew install swiftlint).
# The derived Worker/Sources/MLXAudioCore and MLXAudioSTT are not linted.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_FORMAT=/Library/Developer/CommandLineTools/usr/bin/swift-format
[[ -x "$SWIFT_FORMAT" ]] || SWIFT_FORMAT="$(xcrun --find swift-format)"
command -v swiftlint >/dev/null || { echo "swiftlint is not installed (brew install swiftlint)"; exit 1; }
[[ "$(swiftlint version)" == 0.65.* ]] || echo "note: .swiftlint.yml was written for SwiftLint 0.65; this is $(swiftlint version)"
files=()
while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'Package.swift' 'Sources/*.swift' 'Tests/*.swift' 'Packages/*.swift' \
  'Worker/Package.swift' 'Worker/Sources/SmallMGEMM/*.swift' 'Worker/Sources/VellaWorker/*.swift' \
  'Worker/Sources/VellaStreamingWorker/*.swift' 'Worker/Sources/VellaWorkerSupport/*.swift' 'Worker/Tests/*.swift')
if [[ "${1:-}" == --fix ]]; then "$SWIFT_FORMAT" format --configuration .swift-format --in-place --parallel "${files[@]}"; fi
"$SWIFT_FORMAT" lint --strict --configuration .swift-format --parallel "${files[@]}"
swiftlint lint --strict --quiet
echo "lint: ${#files[@]} files clean"
