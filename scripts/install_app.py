"""Transactional per-user installation, called by install.sh after prerequisite checks."""
import os
import json
import importlib.util
import selectors
import time
import signal
import fcntl
from contextlib import contextmanager
import pathlib
import shutil
import subprocess
import sys
import tempfile


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=1800, **kwargs)


def restore(path, data):
    if data is None:
        path.unlink(missing_ok=True)
    else:
        fd, name = tempfile.mkstemp(prefix='.vella-restore-', dir=path.parent)
        pending = pathlib.Path(name)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(data)
            pending.replace(path)
        finally:
            pending.unlink(missing_ok=True)


def reject_link(path, boundary):
    # Do not follow linked destinations or linked user-data ancestors. System
    # aliases above the user's home (for example /var) are outside this check.
    for candidate in (path, *path.parents):
        if candidate == boundary:
            break
        if candidate.is_symlink() or (candidate.is_file() and candidate.stat().st_nlink > 1):
            sys.exit(f'Linked installer destination preserved: {candidate}. Choose an unlinked location.')


@contextmanager
def installation_lock(support):
    support.mkdir(parents=True, exist_ok=True)
    # Keep this inode permanently: unlinking it allows two independent locks.
    fd = os.open(support / '.installer.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('Another Vella installer is running. Wait for it to finish, then rerun this installer.')
        yield
    finally:
        os.close(fd)


DEFAULT_MODEL_ID = 'parakeet-tdt-0.6b-v3-mlx-4bit'


def check_model_destination(destination, support):
    reject_link(destination, support.parent)
    if destination.exists():
        for path in destination.rglob('*'):
            if path.is_symlink() or (path.is_file() and path.stat().st_nlink > 1):
                raise ValueError(f'Linked/shared model asset preserved: {path}')


def download_default(source, support, python, timeout=1800):
    """Download only; caller owns transactional registration and selection.

    Safe isolated qualification: supply a temporary support directory and the
    prepared runtime Python. This function never reads/writes user settings.
    """
    catalog = source / 'Resources/models.json'
    entry = next(x for x in json.loads(catalog.read_text()) if x['id'] == DEFAULT_MODEL_ID)
    destination = support / 'Models' / entry['id']
    check_model_destination(destination, support)
    worker = source / 'Resources/benchmark_worker.py'
    args = [str(python), '-B', str(worker), 'download', '--catalog', str(catalog),
            '--model-id', entry['id'], '--models-dir', str(support / 'Models')]
    print(f"Installing recommended Parakeet Q4 ({entry['downloadBytes']/1_000_000:.0f} MB). "
          'No Hugging Face account is required. Interrupted downloads resume when you rerun the installer.', flush=True)
    result = None
    # A process group also bounds Hub helper threads/children on timeout or Ctrl-C.
    with subprocess.Popen(args, stdout=subprocess.PIPE, start_new_session=True,
                          env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HF_HUB_DISABLE_TELEMETRY='1')) as process:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + timeout
                last_progress = None
                buffer = b''
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(args, timeout)
                    if b'\n' not in buffer:
                        if not selector.select(min(remaining, 1)):
                            continue
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            if buffer:
                                raise ValueError('Incomplete download protocol line')
                            break
                        buffer += chunk
                        if len(buffer) > 1024 * 1024:
                            raise ValueError('Oversized download protocol output')
                        if b'\n' not in buffer:
                            continue
                    line, buffer = buffer.split(b'\n', 1)
                    event = json.loads(line)
                    if event.get('event') == 'progress':
                        total = event.get('total', 0)
                        percent = min(99, int(100 * event.get('completed', 0) / total)) if total else None
                        progress = (event.get('message', 'Downloading…'), percent)
                        if progress != last_progress:
                            print(progress[0] + (f' {percent}%' if percent is not None else ''), flush=True)
                            last_progress = progress
                    elif event.get('event') == 'error':
                        raise ValueError(event.get('message', 'Download failed'))
                    elif event.get('event') == 'installed':
                        if result is not None:
                            raise ValueError('Duplicate model installation result')
                        result = event
                status = process.wait(timeout=max(.01, deadline - time.monotonic()))
                if status:
                    raise subprocess.CalledProcessError(status, args)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            raise
    if not result or any(result.get(key) != value for key, value in
                         [('modelID', entry['id']), ('revision', entry['revision']),
                          ('path', str(destination))]):
        raise ValueError('Default model result does not match the pinned ID, revision and destination')
    check_model_destination(destination, support)
    spec = importlib.util.spec_from_file_location('vella_download_validation', worker)
    validation = importlib.util.module_from_spec(spec)
    # Import without ever leaving bytecode in signed/bundled resources.
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(validation)
    finally:
        sys.dont_write_bytecode = previous
    validation.validate_model(destination, entry)
    print('Parakeet Q4 download verified: 100%.', flush=True)
    return dict(path=str(destination), revision=entry['revision'], name=entry['name'],
                quantization=entry['quantization'])


def install(source, work):
    home = pathlib.Path.home()
    support = home / 'Library/Application Support/Vella'
    app = pathlib.Path(os.environ.get('VELLA_APP_PATH', str(home / 'Applications/Vella.app'))).absolute()
    reject_link(app, home)
    reject_link(support, home)
    for name in ('config.json', 'config.before-runtime.json', 'config.runtime-pending.json', 'Runtimes', '.installer.lock', 'models-installed.json', 'Models'):
        reject_link(support / name, home)
    with installation_lock(support):
        install_locked(source, work, support, app)


def install_locked(source, work, support, app):
    if app.name != 'Vella.app' or app.is_symlink():
        sys.exit('Choose an unlinked destination named Vella.app.')
    if app.exists():
        details = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, timeout=10)
        if 'Authority=' in details.stderr + details.stdout:
            sys.exit('Certificate-signed installation preserved. Update it using its existing signing workflow; this installer creates ad-hoc builds.')
        if details.returncode:
            sys.exit('Cannot inspect the existing app signing identity. Existing installation preserved; repair or inspect it before retrying.')
        info = app / 'Contents/Info.plist'
        import plistlib
        if not info.is_file() or plistlib.loads(info.read_bytes()).get('CFBundleIdentifier') != 'dev.vella.dictation':
            sys.exit('Destination is not an existing Vella installation.')
    # Existing settings/registry count as an installation even if its app was removed.
    first_install = not app.exists() and not any((support / name).exists() for name in
                                                ('config.json', 'models-installed.json'))
    staged = work / 'Vella.app'
    env = dict(os.environ, VELLA_APP_PATH=str(staged), VELLA_SIGN_IDENTITY='-', VELLA_REGISTER_APP='0')
    # Build and prepare packages before closing or changing the working installation.
    run([str(source / 'scripts/build.sh')], cwd=source, env=env)
    prepared = run([str(source / 'scripts/setup-backend.sh'), '--runtime-only'], cwd=source,
        env=dict(os.environ, VELLA_SUPPORT_DIR=str(support)), stdout=subprocess.PIPE, text=True)
    if prepared.stdout:
        print(prepared.stdout, end='', flush=True)
    stop = r'''
import AppKit
let path = ProcessInfo.processInfo.environment["VELLA_DESTINATION"]!
if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.vella.dictation"),
   known.path != path, FileManager.default.fileExists(atPath: known.path) {
    fputs("An existing Vella copy is registered at another path. Set VELLA_APP_PATH to that copy rather than creating a second installation.\n", stderr); exit(1)
}
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.vella.dictation" }
if apps.contains(where: { $0.bundleURL?.path != path }) {
    fputs("Another Vella installation is running. Quit it and set VELLA_APP_PATH to its existing path to update that copy.\n", stderr); exit(1)
}
let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella/dictation-status.json")
if let data = try? Data(contentsOf: state), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let phase = object["phase"] as? String, ["recording", "preparing", "transcribing"].contains(phase) {
    fputs("Finish dictation before installing.\n", stderr); exit(1)
}
apps.forEach { _ = $0.terminate() }
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
if apps.contains(where: { !$0.isTerminated }) { exit(1) }
'''
    run(['xcrun', 'swift', '-e', stop], env=dict(os.environ, VELLA_DESTINATION=str(app)))
    tracked = [support / 'config.json', support / 'config.before-runtime.json',
               support / 'models-installed.json']
    snapshots = {p: p.read_bytes() if p.exists() else None for p in tracked}
    app.parent.mkdir(parents=True, exist_ok=True)
    # Same-volume staging keeps the final directory swaps atomic.
    transaction = pathlib.Path(tempfile.mkdtemp(prefix='.vella-update-', dir=app.parent))
    previous = transaction / 'previous.app'
    replacement = transaction / 'replacement.app'
    committed = False
    try:
        shutil.copytree(staged, replacement, symlinks=True)
        run(['codesign', '--verify', '--strict', str(replacement)])
        default = None
        if first_install:
            prefix = 'Prepared Vella runtime: '
            runtimes = [line[len(prefix):] for line in (prepared.stdout or '').splitlines() if line.startswith(prefix)]
            if len(runtimes) != 1 or not pathlib.Path(runtimes[0]).is_file():
                raise ValueError('Prepared runtime did not report one usable Python executable')
            default = download_default(source, support, runtimes[0])
        run([str(source / 'scripts/setup-backend.sh'), '--migrate-runtime'], cwd=source,
            env=dict(os.environ, VELLA_SUPPORT_DIR=str(support),
                     VELLA_INITIAL_MODEL=default['path'] if default else ''))
        if default is not None:
            settings = json.loads((support / 'config.json').read_text())
            if settings.get('model') != default['path']:
                raise ValueError('First-install configuration did not retain the verified default')
            restore(support / 'models-installed.json', json.dumps({DEFAULT_MODEL_ID: default}, indent=2).encode())
        if app.exists():
            app.rename(previous)
        try:
            replacement.rename(app)
        except BaseException:
            if previous.exists():
                previous.rename(app)
            raise
        committed = True
    finally:
        if not committed:
            if first_install:
                print('First installation did not complete. Configuration and registry are being rolled back; '
                      'partial weights are never selected. Rerun the installer to resume retained downloads.',
                      file=sys.stderr)
            for path, data in snapshots.items():
                restore(path, data)
        if not committed and previous.exists():
            print(f'Previous app retained for recovery at {previous}', file=sys.stderr)
        else:
            try:
                shutil.rmtree(transaction)
            except OSError as error:
                message = f'Cleanup incomplete at {transaction}: {error}.'
                if committed:
                    message += ' The installed app was not rolled back.'
                print(message, file=sys.stderr)
    print(f'Installed {app}. Models, recordings and microphone choices preserved.')
    print('Parakeet Q4 is ready and selected for Dictation.' if first_install else 'Existing model selections retained.')
    print('Approve microphone and Accessibility when requested.')
    print('Ad-hoc updates can require renewing macOS privacy approval. No security settings were disabled.')
    try:
        run(['open', str(app)])
    except (OSError, subprocess.SubprocessError) as error:
        sys.exit(f'Installation completed, but Vella could not be opened: {error}. '
                 f'Open {app} in Finder and check System Settings > Privacy & Security if macOS blocks it. '
                 'The installed app and migrated configuration were retained; no rollback occurred.')


if __name__ == '__main__':
    install(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
