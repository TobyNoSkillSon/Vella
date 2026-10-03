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
if not ref:
    paths = subprocess.check_output(['git', 'ls-files', '*.sh', '.github/workflows/*'],
                                    text=True, timeout=10).splitlines()
    early = re.compile(r'(?<!\|)\|(?!\|)\s*(?:grep\s+-[A-Za-z]*q\b|head\b)')
    for path in paths:
        for number, line in enumerate(Path(path).read_text().splitlines(), 1):
            if early.search(line):
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

    def run(name, body, case):
        script = root / 'scripts' / f'{name}.sh'
        script.write_text(body)
        log = root / f'{name}-{case}.log'
        with log.open('w') as output:
            p = subprocess.Popen(['/bin/bash', str(script)], env=dict(env, CASE=case),
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
if failures:
    raise SystemExit('\n'.join(failures))
print('pipefail: detached non-interactive build/CI identity checks pass; absent identity and producer errors fail closed')
PY
