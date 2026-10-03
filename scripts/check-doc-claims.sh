#!/usr/bin/env bash
# Public prose must not repeat the claims the pre-release audits found false, and must keep the corrected ones.
#   scripts/check-doc-claims.sh [--root DIR]   check README, user guide, skill, contributor and per-model docs
#   scripts/check-doc-claims.sh --selftest     prove each rule fires on a bad fixture and passes on a good one
# release-check.sh runs both. Add a rule here when an audit finds another stale claim.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Files that make claims about the product. Generated blocks inside them are covered too.
doc_files() {
  local root="$1" f
  for f in README.md AGENTS.md CONTRIBUTING.md CHANGELOG.md SECURITY.md docs/USAGE.md Resources/SKILL.md Resources/AGENT_GUIDE.md \
           Worker/Sources/MLXAudioSTT/*/README.md; do
    [[ -f "$root/$f" ]] && echo "$f"
  done
}

# Files that ship or are published (app resources, Pages site, README, changelog, user docs). The whisper.cpp comparison was
# withdrawn (Toby, 3 Oct 2026): none of them may name a competitor or carry its data. Worker model READMEs are not listed:
# they credit upstream techniques by name and make no comparison.
shipped_files() {
  local root="$1" f
  for f in README.md CHANGELOG.md docs/USAGE.md docs/*.js docs/*.html Resources/*.json Resources/*.md; do
    [[ -f "$root/$f" ]] && echo "$f"
  done
  return 0
}

# forbid FILE-GLOB-REGEX PATTERN WHY: no matching line may exist in the matching files.
# require FILE PATTERN WHY: the file must contain a matching line.
check() {
  local root="$1" bad=0 f hits; hits="$(mktemp "${TMPDIR:-/tmp}/doc-claims-hits.XXXXXX")"
  forbid() {
    local pattern="$1" why="$2"
    while IFS= read -r f; do
      if grep -n -i -E -e "$pattern" "$root/$f" >"$hits" 2>/dev/null; then
        sed "s|^|$f:|" "$hits" | cut -c1-200; echo "  -> $why"; bad=1
      fi
    done < <(doc_files "$root")
  }
  require() {
    local file="$1" pattern="$2" why="$3"
    grep -q -i -E -e "$pattern" "$root/$file" 2>/dev/null || { echo "$file: missing: $why"; bad=1; }
  }
  # Item 4: lever rows describe the defaults that ship.
  forbid 'default: off' 'a lever table says "Default: off"; kept levers are on by default'
  # Item 5: Parakeet v3 downloads FP32 and converts once.
  forbid "only the checkpoint's native 16-bit weights are downloaded" 'Parakeet v3 is pinned to an FP32 source (converted once to BF16 at Get)'
  require README.md 'FP32.*converts? (it )?once|converted once' 'README must state the FP32 to BF16 conversion of Parakeet v3'
  # Item 8: privacy.
  forbid 'nothing leaves' 'say "your audio and transcripts never leave your Mac" plus the update-check and download facts'
  forbid 'check for a newer release after a transcription' 'the update check runs at launch and then daily'
  require README.md 'audio and transcripts never leave your Mac' 'README privacy sentence'
  require README.md 'at most once a day \(at launch when due\)'  'README update-check cadence'
  require Resources/SKILL.md 'audio and transcripts never leave' 'skill privacy sentence'
  # Item 9: the Exact contract.
  forbid 'output identical to Standard|identical to Standard' 'Exact is exact-only components that match Standard on the load-time self-test, not an identity guarantee'
  forbid 'reorder no sums|only kernels whose output equals Standard|vendor.s quantization-aware 4-bit' 'Exact is a load-time self-test contract; low-bit tiers are plain local affine derivations'
  # Item 10: WER is English WER.
  require README.md 'English word error rate on the 167 English minutes' 'README WER definition'
  require docs/USAGE.md 'English word error rate' 'user guide WER definition'
  # Item 11: SDK snippet.
  forbid 'base_url="http://127\.0\.0\.1:[0-9]+' 'a hard-coded port; use subprocess.check_output(["vella", "url"])'
  require README.md 'check_output\(\["vella", "url"\]' 'README SDK snippet must call `vella url`'
  # Item 16: the Vireo repository is private (404).
  forbid 'github\.com/TobyNoSkillSon/Vireo' 'the Vireo link returns 404'
  # Withdrawn comparison: no competitor name or competitor_comparisons key in anything shipped or published.
  while IFS= read -r f; do
    if grep -n -i -E -e 'whisper\.cpp|whispercpp|whisper-cpp|wcpp|macwhisper|buzz|competitor_comparisons' "$root/$f" >"$hits" 2>/dev/null; then
      sed "s|^|$f:|" "$hits" | cut -c1-200; echo "  -> the whisper.cpp comparison is withdrawn; no competitor name or competitor_comparisons ships"; bad=1
    fi
  done < <(shipped_files "$root")
  rm -f "$hits"
  return $bad
}

selftest() {
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/doc-claims.XXXXXX")"; trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/good/docs" "$t/good/Resources"
  cat >"$t/good/README.md" <<'E'
Parakeet v3's pinned source is FP32; Vella converts it once to BF16 at Get.
English word error rate on the 167 English minutes of the suite.
Your audio and transcripts never leave your Mac. A check at most once a day (at launch when due).
client = OpenAI(base_url=subprocess.check_output(["vella", "url"], text=True).strip())
E
  echo 'English word error rate' >"$t/good/docs/USAGE.md"
  echo 'audio and transcripts never leave the machine' >"$t/good/Resources/SKILL.md"
  check "$t/good" >/dev/null || { echo "selftest: the good fixture was refused"; return 1; }
  local rules=(
    "| Native int8 | VELLA_X=1 | rev | inexact | result | Default: off |"
    "Only the checkpoint's native 16-bit weights are downloaded"
    "nothing leaves the machine"
    "a once-a-day check for a newer release after a transcription"
    "Exact offers only kernels whose output is identical to Standard"
    "Exact components reorder no sums"
    "a vendor's quantization-aware 4-bit"
    'client = OpenAI(base_url="http://127.0.0.1:63080/v1")'
    "[Vireo](https://github.com/TobyNoSkillSon/Vireo)"
    "| whisper.cpp synthetic fixture | 91.23 | 2.34× |"
    "| wcpp synthetic fixture | test-suite (1.234) |"
    "MacWhisper and Vella compared"
    "Buzz.app transcription rows"
    '"competitor_comparisons": {}'
  )
  local i=0 rule
  for rule in "${rules[@]}"; do
    i=$((i + 1)); rm -rf "$t/bad$i"; cp -R "$t/good" "$t/bad$i"
    printf '%s\n' "$rule" >>"$t/bad$i/README.md"
    if check "$t/bad$i" >/dev/null; then echo "selftest: rule $i not enforced: $rule"; return 1; fi
  done
  # a mention planted in a shipped data file or the Pages site is refused too, not only in prose
  local planted
  for planted in Resources/benchmarks.json docs/data.js docs/index.html Resources/AGENT_GUIDE.md; do
    rm -rf "$t/plant"; cp -R "$t/good" "$t/plant"; printf '%s\n' 'whisper.cpp' >>"$t/plant/$planted"
    if check "$t/plant" >/dev/null; then echo "selftest: a planted mention in $planted was accepted"; return 1; fi
  done
  # a missing required claim is refused too
  rm -rf "$t/bare"; cp -R "$t/good" "$t/bare"; : >"$t/bare/README.md"
  if check "$t/bare" >/dev/null; then echo "selftest: missing required claims were accepted"; return 1; fi
  echo "check-doc-claims selftest: good fixture passes; ${#rules[@]} forbidden claims, planted competitor mentions in shipped files and the missing-claims case are refused"
}

case "${1:-}" in
  --selftest) selftest ;;
  --root) [[ $# -eq 2 ]] || { echo "usage: $0 [--root DIR | --selftest]" >&2; exit 2; }
          check "$2" && echo "check-doc-claims: public prose matches the audited claims" ;;
  "") check "$HERE" && echo "check-doc-claims: public prose matches the audited claims" ;;
  *) echo "usage: $0 [--root DIR | --selftest]" >&2; exit 2 ;;
esac
