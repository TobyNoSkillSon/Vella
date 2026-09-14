#!/bin/bash
# Reuse an installed Python; isolate packages, not the interpreter. No model downloads.
set -euo pipefail
ROOT="${VELLA_SUPPORT_DIR:-$HOME/Library/Application Support/Vella}"
MODE="${1:-setup}"
case "$MODE" in setup|--runtime-only|--migrate-runtime) ;; *) echo 'Usage: setup-backend.sh [--runtime-only|--migrate-runtime]' >&2; exit 2;; esac
if [[ "$MODE" == setup && -f "$ROOT/config.json" ]]; then
  echo 'Existing configuration retained. Use --migrate-runtime to explicitly update Vella runtime dependencies.'
  exit 0
fi
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1 || ! "$PYTHON" -c 'import sys; assert (3,12) <= sys.version_info[:2] < (3,15)' 2>/dev/null; then
  echo 'Python 3.12–3.14 is required. Install it (for example: brew install python@3.12), then rerun. Or set PYTHON=/path/to/python3.' >&2
  exit 1
fi
"$PYTHON" -c 'import platform; assert platform.system()=="Darwin" and platform.machine()=="arm64", "Apple Silicon macOS required"; assert int(platform.mac_ver()[0].split(".")[0])>=14, "macOS 14+ required"'
"$PYTHON" - "$ROOT" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'dictation-status.json'
if p.exists() and json.loads(p.read_text()).get('phase') in ('preparing','recording','transcribing'):
    sys.exit('Finish dictation before updating the runtime. Nothing changed.')
PY
umask 077
PYVER="$("$PYTHON" -c 'import sys; print("%s.%s" % sys.version_info[:2])')"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/runtime-requirements.txt"
[[ -f "$LOCK" ]] || LOCK="$HERE/../Resources/runtime-requirements.txt"
LOCK_HASH="$("$PYTHON" -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()[:12])' "$LOCK")"
TARGET="$ROOT/Runtimes/mlx-audio-0.5.1-mlx-0.32.2-$LOCK_HASH-python-$PYVER"
"$PYTHON" - "$ROOT" "$TARGET" <<'PY'
import pathlib,sys
root,target=map(pathlib.Path,sys.argv[1:3])
for path in (root,root/'Runtimes',target,target/'.vella-ready',root/'config.json',
             root/'config.before-runtime.json',root/'config.runtime-pending.json'):
    if path.is_symlink():
        sys.exit(f'Linked runtime or configuration preserved: {path}. Choose an unlinked Vella support directory.')
PY
mkdir -p "$ROOT/Runtimes"
if [[ ! -f "$TARGET/.vella-ready" ]]; then
  "$PYTHON" -m venv "$TARGET"
  "$TARGET/bin/python" -m pip install --disable-pip-version-check -r "$LOCK" >&2
  "$TARGET/bin/python" -m pip check >&2
  "$TARGET/bin/python" -c 'import mlx.core; from mlx_audio.stt.utils import load_model'
  touch "$TARGET/.vella-ready"
fi
"$TARGET/bin/python" - "$LOCK" <<'PY'
from importlib import metadata
import pathlib,sys
import mlx.core
from mlx_audio.stt.utils import load_model
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#'): continue
    name,version=line.split('==');name=name.split('[')[0]
    if metadata.version(name)!=version:sys.exit('Runtime differs from the tested package lock; configuration was not changed.')
PY
"$TARGET/bin/python" - "$ROOT" "$TARGET" "$MODE" <<'PY'
import json,os,pathlib,sys
root,target=map(pathlib.Path,sys.argv[1:3]); mode=sys.argv[3]
if mode=='--runtime-only':
    print('Prepared Vella runtime:',target/'bin/python');sys.exit(0)
config=root/'config.json'
old=config.read_bytes() if config.exists() else None
# Only the installer supplies this after the pinned download is verified.
# Seed it in the first atomic config write: interruption must not leave an
# empty model configuration that looks like an existing installation on retry.
settings=json.loads(old) if old else dict(model=os.environ.get('VELLA_INITIAL_MODEL',''),preferredMicrophone='MacBook Pro Microphone',fallbackMicrophone='MacBook Pro Microphone')
settings['executable']=str(target/'bin/python');settings.pop('port',None)
if old is not None and settings==json.loads(old):
    print('Vella runtime already selected; configuration and rollback copy unchanged.');sys.exit(0)
if old is not None:
    backup=root/'config.before-runtime.json';backup.write_bytes(old)
pending=root/'config.runtime-pending.json';pending.write_text(json.dumps(settings,indent=2));pending.replace(config)
print('Vella private runtime ready. Existing model and microphone choices retained.' if old else
      'Runtime ready. Verified default model selected.' if settings.get('model') else
      'Runtime ready. Open Vella, then Install a model and choose Use.')
PY
