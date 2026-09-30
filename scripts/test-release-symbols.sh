#!/usr/bin/env bash
# CPU-only packaging regression: app/CLI case collision, completeness and DWARF checks.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d /tmp/vella-symbol-fixture.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
touch "$ROOT/CaseProbe"
if [[ -e "$ROOT/caseprobe" ]]; then echo 'Fixture filesystem: case-insensitive'; else echo 'Fixture filesystem: case-sensitive'; fi
APP="$ROOT/Vella.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
i=0
for path in MacOS/Vella MacOS/VellaWorker MacOS/VellaModelTool Helpers/VellaInstallTool Helpers/vella; do
  i=$((i+1))
  echo "int fixture_$i(void) {return $i;} int main(void) {return fixture_$i();}" > "$ROOT/$i.c"
  xcrun clang -g -c "$ROOT/$i.c" -o "$ROOT/$i.o"
  xcrun clang "$ROOT/$i.o" -o "$APP/Contents/$path"
done
"$PROJECT/scripts/strip-release.sh" "$APP" "$ROOT/Symbols"
[[ $(find "$ROOT/Symbols/dSYMs" -name '*.dSYM' | wc -l) == 5 ]]
[[ $(awk '{print $1}' "$ROOT/Symbols/UUIDS.txt" | sort -u | wc -l) == 5 ]]
mv "$ROOT/Symbols/dSYMs/MacOS-Vella.dSYM" "$ROOT/app.dSYM"
if "$PROJECT/scripts/verify-release-symbols.sh" "$APP" "$ROOT/Symbols"; then echo 'Missing app dSYM was accepted' >&2; exit 1; fi
mv "$ROOT/app.dSYM" "$ROOT/Symbols/dSYMs/MacOS-Vella.dSYM"
cp "$ROOT/Symbols/UUIDS.txt" "$ROOT/UUIDS.txt"
echo '00000000-0000-0000-0000-000000000000 MacOS/ghost' >> "$ROOT/Symbols/UUIDS.txt"
if "$PROJECT/scripts/verify-release-symbols.sh" "$APP" "$ROOT/Symbols"; then echo 'Uncovered UUID was accepted' >&2; exit 1; fi
cp "$ROOT/UUIDS.txt" "$ROOT/Symbols/UUIDS.txt"
# dsymutil on already-stripped code warns but exits zero: the final check must reject its empty DWARF.
rm -rf "$ROOT/Symbols/dSYMs/MacOS-Vella.dSYM"
xcrun dsymutil "$APP/Contents/MacOS/Vella" -o "$ROOT/Symbols/dSYMs/MacOS-Vella.dSYM"
if "$PROJECT/scripts/verify-release-symbols.sh" "$APP" "$ROOT/Symbols"; then echo 'Empty DWARF was accepted' >&2; exit 1; fi
"$PROJECT/scripts/strip-release.sh" "$APP"
echo 'PASS: path-named symbols, five distinct UUIDs, missing/extra/empty symbols refused, plain strip retains nothing'
