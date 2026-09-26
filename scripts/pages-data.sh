#!/usr/bin/env bash
# Write docs/data.js for the benchmark site (GitHub Pages serves docs/) from Resources/benchmarks.json and
# Resources/models.json, unchanged. Run after either file changes and commit the result;
# Tests/VellaCoreTests/DocsTests checks that docs/data.js matches them.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  printf '// Written by scripts/pages-data.sh from Resources/benchmarks.json and Resources/models.json.\n'
  printf 'const VELLA_BENCHMARKS = %s;\n' "$(cat Resources/benchmarks.json)"
  printf 'const VELLA_MODELS = %s;\n' "$(cat Resources/models.json)"
} >docs/data.js.tmp
mv docs/data.js.tmp docs/data.js
echo "wrote docs/data.js"
