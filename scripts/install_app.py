"""Transactional per-user installation, called by install.sh after prerequisite checks."""
import os
import pathlib
import shutil
import subprocess
import sys


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=1800, **kwargs)


def restore(path, data):
    if data is None:
        path.unlink(missing_ok=True)
    else:
        pending = path.with_suffix('.install-pending')
        pending.write_bytes(data)
        pending.chmod(0o600)
        pending.replace(path)


def install(source, work):
    home = pathlib.Path.home()
    support = home / 'Library/Application Support/Vella'
    app = pathlib.Path(os.environ.get('VELLA_APP_PATH', str(home / 'Applications/Vella.app'))).absolute()
    if app.name != 'Vella.app' or app.is_symlink():
        sys.exit('Choose an unlinked destination named Vella.app.')
    if app.exists():
        details = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, timeout=10)
        if 'Authority=' in details.stderr + details.stdout:
            sys.exit('Certificate-signed installation preserved. Update it using its existing signing workflow; this installer creates ad-hoc builds.')
        info = app / 'Contents/Info.plist'
        import plistlib
        if not info.is_file() or plistlib.loads(info.read_bytes()).get('CFBundleIdentifier') != 'dev.vella.dictation':
            sys.exit('Destination is not an existing Vella installation.')
    staged = work / 'Vella.app'
    env = dict(os.environ, VELLA_APP_PATH=str(staged), VELLA_SIGN_IDENTITY='-', VELLA_REGISTER_APP='0')
    # Build and prepare packages before closing or changing the working installation.
    run([str(source / 'scripts/build.sh')], cwd=source, env=env)
    run([str(source / 'scripts/setup-backend.sh'), '--runtime-only'], cwd=source,
        env=dict(os.environ, VELLA_SUPPORT_DIR=str(support)))
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
    run(['swift', '-e', stop], env=dict(os.environ, VELLA_DESTINATION=str(app)))
    tracked = [support / 'config.json', support / 'config.before-runtime.json']
    snapshots = {p: p.read_bytes() if p.exists() else None for p in tracked}
    app.parent.mkdir(parents=True, exist_ok=True)
    # Same-volume staging keeps the final directory swaps atomic.
    import tempfile
    transaction = pathlib.Path(tempfile.mkdtemp(prefix='.vella-update-', dir=app.parent))
    previous = transaction / 'previous.app'
    replacement = transaction / 'replacement.app'
    committed = False
    try:
        shutil.copytree(staged, replacement, symlinks=True)
        run(['codesign', '--verify', '--strict', str(replacement)])
        run([str(source / 'scripts/setup-backend.sh'), '--migrate-runtime'], cwd=source,
            env=dict(os.environ, VELLA_SUPPORT_DIR=str(support)))
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
            for path, data in snapshots.items():
                restore(path, data)
        if not committed and previous.exists():
            print(f'Previous app retained for recovery at {previous}', file=sys.stderr)
        else:
            shutil.rmtree(transaction)
    print(f'Installed {app}. Models, recordings and microphone choices preserved.')
    print('Open Models, click Install, then Use. Approve microphone and Accessibility when requested.')
    print('Ad-hoc updates can require renewing macOS privacy approval. No security settings were disabled.')
    run(['open', str(app)])


if __name__ == '__main__':
    install(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
