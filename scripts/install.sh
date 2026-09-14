#!/bin/bash
# Local source build: no developer account, certificate, sudo, or security bypass.
set -euo pipefail
VERSION="0.8.6"
fail() { echo "Vella: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Apple Silicon macOS is required.'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail 'macOS 14 or newer is required.'
xcrun --find swift >/dev/null 2>&1 || fail 'Install Apple’s free Command Line Tools with: xcode-select --install, then rerun. No developer account is needed.'
PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
  for candidate in python3 python3.14 python3.13 python3.12 /opt/homebrew/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys,platform; assert (3,12)<=sys.version_info[:2]<(3,15) and platform.machine()=="arm64"' 2>/dev/null; then
      PYTHON="$(command -v "$candidate")"; break
    fi
  done
fi
[[ -n "$PYTHON" ]] || fail 'Install Python 3.12–3.14 from python.org, then rerun. Or set PYTHON=/path/to/python3. No account is required.'
"$PYTHON" -c 'import sys,platform; assert (3,12)<=sys.version_info[:2]<(3,15) and platform.machine()=="arm64"' 2>/dev/null || fail 'PYTHON must point to compatible Apple Silicon Python 3.12–3.14.'
export PYTHON
# Pin both inputs when using curl. No moving "latest" archive or invented repository URL.
SOURCE_URL="${VELLA_SOURCE_URL:-}"
SOURCE_SHA="${VELLA_SOURCE_SHA256:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vella-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if [[ -z "$SOURCE_URL" && ( -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ) ]]; then
  RELEASE="https://github.com/TobyNoSkillSon/Vella/releases/download/v$VERSION"
  SOURCE_URL="$RELEASE/Vella-$VERSION-source.tar.gz"
  curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 60 "$RELEASE/SHA256SUMS" -o "$WORK/SHA256SUMS"
  SOURCE_SHA="$("$PYTHON" -c 'import pathlib,sys; rows=[x.split() for x in pathlib.Path(sys.argv[1]).read_text().splitlines()]; matches=[r[0] for r in rows if len(r)==2 and r[1]==sys.argv[2]]; sys.exit("Release checksum is missing or ambiguous; nothing installed.") if len(matches)!=1 else print(matches[0])' "$WORK/SHA256SUMS" "Vella-$VERSION-source.tar.gz")"
fi
if [[ -n "$SOURCE_URL" ]]; then
  [[ "$SOURCE_URL" == https://* ]] || fail 'The source archive URL must use HTTPS.'
  [[ "$SOURCE_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Set VELLA_SOURCE_SHA256 to the published source archive checksum.'
  curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 "$SOURCE_URL" -o "$WORK/source.tar.gz"
  "$PYTHON" - "$WORK" "$SOURCE_SHA" <<'PY'
import hashlib,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]); archive=root/'source.tar.gz'
if hashlib.sha256(archive.read_bytes()).hexdigest()!=sys.argv[2].lower():sys.exit('Source checksum mismatch; nothing installed.')
with tarfile.open(archive) as tar:
    entries=tar.getmembers()
    if len(entries)>20000 or sum(x.size for x in entries)>1024**3:sys.exit('Source archive exceeds installer bounds.')
    for entry in entries:
        path=pathlib.PurePosixPath(entry.name)
        if path.is_absolute() or '..' in path.parts or not (entry.isfile() or entry.isdir()):sys.exit('Unsafe source archive entry.')
    tar.extractall(root/'source',filter='data')
roots=list((root/'source').iterdir())
if len(roots)!=1 or not (roots[0]/'Package.swift').is_file():sys.exit('Expected one Vella source folder.')
(root/'source-path').write_text(str(roots[0]))
PY
  SOURCE="$(cat "$WORK/source-path")"
else
  [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] || fail 'Piped installation requires VELLA_SOURCE_URL and VELLA_SOURCE_SHA256 from the release instructions.'
  SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -f "$SOURCE/Package.swift" ]] || fail 'Run from a Vella checkout, or provide a pinned source archive.'
fi
exec_args=("$PYTHON" "$SOURCE/scripts/install_app.py" "$SOURCE" "$WORK")
"${exec_args[@]}"
