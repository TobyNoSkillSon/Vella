import importlib.util
import io
import os
import pathlib
import plistlib
import hashlib
import platform
import re
import sys
import tarfile
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT/'scripts/install_app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_replacement_and_failed_migration_preserve_user_data(self):
        for failure in ('none', 'migration', 'swap', 'launch'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory)
                work = home/'work'; work.mkdir()
                app = home/'Applications/Vella.app'; app.mkdir(parents=True)
                (app/'Contents').mkdir()
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.vella.dictation'}))
                (app/'old').write_text('old app')
                support = home/'Library/Application Support/Vella'; support.mkdir(parents=True)
                config = support/'config.json'; config.write_bytes(b'original config')
                backup = support/'config.before-runtime.json'; backup.write_bytes(b'original backup')
                model = support/'Models/weights'; model.parent.mkdir(); model.write_bytes(b'weights')
                recording = support/'Recordings/audio'; recording.parent.mkdir(); recording.write_bytes(b'audio')
                def run(args, **kwargs):
                    if args[0].endswith('build.sh'):
                        staged = work/'Vella.app'; staged.mkdir(); (staged/'new').write_text('new app')
                    if args[-1] == '--migrate-runtime':
                        config.write_bytes(b'new config')
                        backup.write_bytes(b'new backup')
                        if failure == 'migration': raise subprocess.CalledProcessError(1,args)
                    if args[0] == 'open' and failure == 'launch':
                        raise subprocess.CalledProcessError(1, args)
                    return subprocess.CompletedProcess(args,0)
                original_rename = pathlib.Path.rename
                def rename(path, target):
                    if path.name == 'replacement.app' and failure == 'swap':
                        raise OSError('fixture swap failure')
                    return original_rename(path, target)
                with patch.object(pathlib.Path, 'rename', rename), patch.object(pathlib.Path,'home',return_value=home), patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}), patch.object(installer,'run',side_effect=run), patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='')):
                    if failure in ('migration', 'swap'):
                        with self.assertRaises((subprocess.CalledProcessError, OSError)): installer.install(ROOT,work)
                        self.assertEqual(config.read_bytes(),b'original config')
                        self.assertEqual(backup.read_bytes(), b'original backup')
                        self.assertTrue((app/'old').exists())
                    elif failure == 'launch':
                        with self.assertRaisesRegex(SystemExit, 'Installation completed.*no rollback occurred'):
                            installer.install(ROOT, work)
                        self.assertTrue((app/'new').exists())
                        self.assertEqual(config.read_bytes(), b'new config')
                    else:
                        installer.install(ROOT,work)
                        self.assertTrue((app/'new').exists())
                    self.assertEqual(recording.read_bytes(),b'audio')
                    self.assertEqual(model.read_bytes(), b'weights')
                    self.assertFalse(list(app.parent.glob('.vella-update-*')))

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Apple Silicon bootstrap')
    def test_piped_bootstrap_checks_hash_and_rejects_traversal(self):
        for mode in ('valid', 'default', 'bad-hash', 'traversal', 'missing-sum', 'duplicate-sum'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=pathlib.Path(directory); archive=root/'source.tar.gz'; marker=root/'dispatched'
                with tarfile.open(archive,'w:gz') as tar:
                    files={'vella/Package.swift':b'// fixture', 'vella/scripts/install_app.py':b'import os,pathlib; pathlib.Path(os.environ["TEST_MARKER"]).write_text("ok")'}
                    if mode=='traversal': files['../escaped']=b'bad'
                    for name,data in files.items():
                        item=tarfile.TarInfo(name);item.size=len(data);tar.addfile(item,io.BytesIO(data))
                bin=root/'bin';bin.mkdir();curl=bin/'curl'
                curl.write_text('#!/bin/bash\nfor arg in "$@"; do if [[ "$arg" == */SHA256SUMS ]]; then /bin/cp "$TEST_SUMS" "${@: -1}"; exit; fi; done\n/bin/cp "$TEST_ARCHIVE" "${@: -1}"\n');curl.chmod(0o755)
                env=dict(os.environ,HOME=str(root),PATH=str(bin)+os.pathsep+os.environ['PATH'],PYTHON=sys.executable,VELLA_SOURCE_URL='https://example.invalid/source.tar.gz',VELLA_SOURCE_SHA256='0'*64 if mode=='bad-hash' else hashlib.sha256(archive.read_bytes()).hexdigest(),TEST_ARCHIVE=str(archive),TEST_MARKER=str(marker))
                version = re.search(r'(?:VERSION="|releases/download/v)([0-9]+\.[0-9]+\.[0-9]+)', (ROOT/'scripts/install.sh').read_text()).group(1)
                sums=root/'SHA256SUMS'; sums.write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+f'  Vella-{version}-source.tar.gz\n')
                if mode == 'missing-sum': sums.write_text('')
                if mode == 'duplicate-sum': sums.write_text(sums.read_text()*2)
                env['TEST_SUMS']=str(sums)
                if mode in ('default', 'missing-sum', 'duplicate-sum'):
                    env.pop('VELLA_SOURCE_URL'); env.pop('VELLA_SOURCE_SHA256')
                result=subprocess.run(['bash'],input=(ROOT/'scripts/install.sh').read_text(),env=env,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode==0,mode in ('valid','default'),result.stderr)
                self.assertEqual(marker.exists(),mode in ('valid','default'))

    def test_signed_installation_refused_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            app=pathlib.Path(directory)/'Vella.app'; app.mkdir()
            with patch.object(pathlib.Path, 'home', return_value=pathlib.Path(directory)), patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}), patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='Authority=existing certificate')), patch.object(installer,'run') as run:
                with self.assertRaises(SystemExit): installer.install(ROOT,pathlib.Path(directory))
                run.assert_not_called()

    def test_symlink_destination_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); target=root/'target'; target.mkdir()
            app=root/'Vella.app'; app.symlink_to(target)
            with patch.object(pathlib.Path, 'home', return_value=root), patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}):
                with self.assertRaises(SystemExit): installer.install(ROOT,root)

    def test_unknown_signing_identity_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            app = home/'Vella.app'; app.mkdir()
            with patch.object(pathlib.Path, 'home', return_value=home), patch.dict(os.environ, {'VELLA_APP_PATH': str(app)}), patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, stdout='', stderr='inspection failed')), patch.object(installer, 'run') as run:
                with self.assertRaisesRegex(SystemExit, 'Cannot inspect.*preserved'):
                    installer.install(ROOT, home/'work')
                run.assert_not_called()

    def test_restore_does_not_follow_predictable_pending_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            victim = root/'external'; victim.write_bytes(b'preserved')
            (root/'config.install-pending').symlink_to(victim)
            installer.restore(root/'config.json', b'restored')
            self.assertEqual((root/'config.json').read_bytes(), b'restored')
            self.assertEqual(victim.read_bytes(), b'preserved')
            self.assertFalse(list(root.glob('.vella-restore-*')))

    def test_lock_excludes_other_process_and_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            support = pathlib.Path(directory)/'support'
            code = ('import importlib.util,pathlib,sys; '
                    's=importlib.util.spec_from_file_location("i",sys.argv[1]); '
                    'm=importlib.util.module_from_spec(s);s.loader.exec_module(m); '
                    '\nwith m.installation_lock(pathlib.Path(sys.argv[2])): print("acquired")')
            def attempt():
                return subprocess.run([sys.executable, '-c', code, str(ROOT/'scripts/install_app.py'),
                                       str(support)], capture_output=True, text=True, timeout=10)
            with self.assertRaisesRegex(RuntimeError, 'fixture'):
                with installer.installation_lock(support):
                    result = attempt()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Another Vella installer is running', result.stderr)
                    raise RuntimeError('fixture')
            self.assertEqual(attempt().returncode, 0)
            self.assertTrue((support/'.installer.lock').is_file())

    def test_linked_parent_and_user_data_refused_before_build(self):
        for location in ('Applications', 'Library', 'config.json', 'config.before-runtime.json', 'config.runtime-pending.json', 'Runtimes', '.installer.lock'):
            with self.subTest(location=location), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory)
                support = home/'Library/Application Support/Vella'
                target = home/'external'; target.mkdir()
                (target/'preserved').write_text('untouched')
                if location in ('Applications', 'Library'):
                    (home/location).symlink_to(target)
                else:
                    support.mkdir(parents=True)
                    (support/location).symlink_to(target)
                with patch.object(pathlib.Path, 'home', return_value=home), patch.dict(os.environ, {'VELLA_APP_PATH': str(home/'Applications/Vella.app')}), patch.object(installer, 'run') as run:
                    with self.assertRaisesRegex(SystemExit, 'Linked installer destination preserved'):
                        installer.install(ROOT, home/'work')
                    run.assert_not_called()
                self.assertEqual((target/'preserved').read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
