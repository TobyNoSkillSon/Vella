#!/usr/bin/env bash
# CPU-only, no keychain access: test the actual build preflight and CI identity-check text.
# --source-ref REF runs the same assertions on historical script bytes (old code must fail).
# Read-only extraction prevents the fixture from importing a certificate or compiling/installing an app.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import sys
import tempfile

ref = None
if len(sys.argv) != 1:
    if len(sys.argv) != 3 or sys.argv[1] != '--source-ref':
        raise SystemExit('usage: test-pipefail.sh [--source-ref REF]')
    ref = sys.argv[2]

def source(path):
    if ref:
        return subprocess.check_output(['git', 'show', f'{ref}:{path}'], text=True, timeout=10)
    return Path(path).read_text()

build = source('scripts/build.sh')
# Stop before the first compiler invocation: no build, signing, app, or keychain mutation.
build = build.split('xcrun swift scripts/prepare-build.swift check\n')[0]
ci = source('scripts/ci-keychain.sh')
ci = ci[ci.index('    security find-identity '):ci.index('    echo "Release signing identity ')]
identity = '0123456789ABCDEF0123456789ABCDEF01234567'
failures = []
def early_consumers(text):
    # Join shell continuations; whitespace after the pipe can also contain a physical newline.
    text = re.sub(r'\\\n', ' ', text)
    for match in re.finditer(r'(?<!\|)\|(?!\|)\s*(grep|head)\b([^\n;|&]*)', text):
        command, tail = match.groups()
        if command == 'head':
            yield match.start()
            continue
        try:
            args = shlex.split(tail)
        except ValueError:
            continue
        for arg in args:
            if arg == '--' or not arg.startswith('-'):
                break
            if arg in ('--quiet', '--silent') or (not arg.startswith('--') and 'q' in arg[1:]):
                yield match.start()
                break

for spelling in ['grep -qF pattern', 'grep -F -q pattern', 'grep --quiet pattern', 'grep --silent pattern', 'head -1',
                 '\n grep -q pattern', '\\\n grep -F -q pattern']:
    if not list(early_consumers('producer | ' + spelling)):
        failures.append('static sweep missed ' + repr(spelling))
for safe in ['grep -q pattern file', 'grep -q pattern <<<"text"', 'producer | grep -F pattern >/dev/null', 'producer || grep -q pattern file']:
    if list(early_consumers(safe)):
        failures.append('static sweep false positive ' + safe)
if not ref:
    paths = subprocess.check_output(['git', 'ls-files', '*.sh', '.github/workflows/*'],
                                    text=True, timeout=10).splitlines()
    for path in paths:
        # This embedded-Python fixture contains detection examples, not shell pipelines.
        if path == 'scripts/test-pipefail.sh':
            continue
        text = Path(path).read_text()
        for offset in early_consumers(text):
            number = text[:offset].count('\n') + 1
            failures.append(f'{path}:{number}: early-exit pipeline consumer')
with tempfile.TemporaryDirectory(prefix='vella-pipefail-') as tmp:
    root = Path(tmp)
    (root / 'scripts').mkdir()
    (root / 'bin').mkdir()
    (root / 'home').mkdir()
    fake = root / 'bin/security'
    fake.write_text(f'#!{sys.executable}\n' + r'''
import os, signal, sys, time
assert sys.argv[1:4] == ['find-identity', '-p', 'codesigning'], sys.argv
assert not os.isatty(0) and not os.isatty(1)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
identity = os.environ['VELLA_SIGN_IDENTITY'] if os.environ['CASE'] != 'missing' else 'not-the-identity'
# Identity early in the first section; then a delayed, much larger second section.
os.write(1, ('Policy: Code Signing\n  1) ' + identity + ' "Fixture"\n').encode())
time.sleep(0.1)
os.write(1, b'Valid identities only\n')
for _ in range(64):
    os.write(1, b'  other identity ' + b'x' * 16384 + b'\n')
sys.exit(73 if os.environ['CASE'] == 'producer-error' else 0)
''')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=f'{root / "bin"}:' + os.environ['PATH'],
               HOME=str(root / 'home'), IDENTITY=identity, VELLA_SIGN_IDENTITY=identity,
               VELLA_SIGNING_SHA1=identity, KEYCHAIN=str(root / 'fake.keychain'),
               VELLA_APP_PATH=str(root / 'absent.app'))
    env.pop('VELLA_RELEASE_SYMBOLS_DIR', None)
    env.pop('VELLA_BUILD_VERSION', None)
    env.pop('VELLA_BUILD_NUMBER', None)
    context = '[[ $- != *i* && ! -t 0 && ! -t 1 ]] || exit 90\n'

    def run(name, body, case, extra=None):
        script = root / 'scripts' / f'{name}.sh'
        script.write_text(body)
        log = root / f'{name}-{case}.log'
        with log.open('w') as output:
            p = subprocess.Popen(['/bin/bash', str(script)], env=dict(env, CASE=case, **(extra or {})),
                                 stdin=subprocess.DEVNULL, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
            try:
                rc = p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
                raise
        return rc, log.read_text().strip()

    for name, text in [('build', build), ('ci-keychain', 'set -euo pipefail\n' + ci)]:
        # Verify the pipeline statuses independently, using the exact consumer from each script.
        pipeline = next(line.strip() for line in text.splitlines() if 'security find-identity ' in line)
        pipeline = pipeline[pipeline.index('security find-identity '):]
        pipeline = re.split(r'; then| \|\|', pipeline)[0]
        body = 'set -uo pipefail\n' + context + pipeline + '\nprintf "pipestatus %s\\n" "${PIPESTATUS[*]}"\n'
        _, output = run(name + '-statuses', body, 'present')
        print(f'{name}: detached {output}')
        if output != 'pipestatus 0 0':
            failures.append(f'{name}: expected pipestatus 0 0, got {output}')
        for case, expected in [('present', 0), ('missing', 1), ('producer-error', 1)]:
            rc, output = run(name, text + '\n' + context + 'echo identity-check-passed\n', case)
            if rc != expected or (case == 'present' and 'identity-check-passed' not in output):
                failures.append(f'{name}/{case}: exit {rc}, expected {expected}; {output}')
            else:
                print(f'{name}/{case}: passed (exit {rc})')
    # Read the actual rejection guards; substitute only their producers. No app, compiler, keychain or mount access.
    for command, forbidden in [('codesign', 'Authority=Fixture'), ('nm', '_swift_initBorrow'), ('mount', ' on FIXTURE (read-only)')]:
        fixture = root / 'bin' / command
        fixture.write_text(f'#!{sys.executable}\n' +
                           'import os, sys\n' +
                           f'print({forbidden!r} if os.environ["CASE"] in ("forbidden", "producer-error-forbidden") else "safe output")\n' +
                           'sys.exit(73 if os.environ["CASE"].startswith("producer-error") else 0)\n')
        fixture.chmod(0o755)
    runtime = source('scripts/build.sh')
    runtime = runtime[runtime.index('for binary in '):runtime.index('# Smoke the helpers')]
    signature = build[build.index('if [[ "$IDENTITY" == "-" && -d "$APP" ]]'):build.index('# Pipeline probes')]
    app = root / 'fixture.app'
    app.mkdir()
    cleanup_source = source('scripts/package-dmg.sh')
    cleanup_source = cleanup_source[cleanup_source.index('cleanup() {'):cleanup_source.index('mkdir "$STAGE/unpacked"')]
    for name, text in [('existing-signature', signature), ('runtime-symbols', runtime), ('mount-cleanup', cleanup_source)]:
        for case in ['clean', 'forbidden', 'producer-error', 'producer-error-forbidden']:
            stage = root / (name + '-' + case)
            stage.mkdir()
            body = 'set -euo pipefail\n' + context + text
            extra = dict(IDENTITY='-', APP=str(app), WORKER_BIN='fixture', STAGE=str(stage), MOUNT='FIXTURE')
            if name == 'mount-cleanup':
                # A successful fixture detach permits cleanup; failures in mount must leave stage intact.
                body = 'hdiutil() { return 0; }\n' + body
            rc, output = run(name, body, case, extra)
            expected = 0 if case == 'clean' or (name == 'mount-cleanup' and case == 'forbidden') else 1
            preserved = name != 'mount-cleanup' or not case.startswith('producer-error') or stage.exists()
            if rc != expected or not preserved:
                failures.append(f'{name}/{case}: exit {rc}, expected {expected}; stage preserved={preserved}; {output}')
            else:
                print(f'{name}/{case}: passed (exit {rc})')
if failures:
    raise SystemExit('\n'.join(failures))
print('pipefail: detached identity and rejection guards pass; producer errors fail closed; static spelling fixtures pass')
PY
