import importlib.util
import io
import os
import pathlib
import plistlib
import hashlib
import platform
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
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory)
                work = home/'work'; work.mkdir()
                app = home/'Applications/Vella.app'; app.mkdir(parents=True)
                (app/'Contents').mkdir()
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.vella.dictation'}))
                (app/'old').write_text('old app')
                support = home/'Library/Application Support/Vella'; support.mkdir(parents=True)
                config = support/'config.json'; config.write_bytes(b'original config')
                recording = support/'Recordings/audio'; recording.parent.mkdir(); recording.write_bytes(b'audio')
                def run(args, **kwargs):
                    if args[0].endswith('build.sh'):
                        staged = work/'Vella.app'; staged.mkdir(); (staged/'new').write_text('new app')
                    if args[-1] == '--migrate-runtime':
                        config.write_bytes(b'new config')
                        if failure: raise subprocess.CalledProcessError(1,args)
                    return subprocess.CompletedProcess(args,0)
                with patch.object(pathlib.Path,'home',return_value=home), patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}), patch.object(installer,'run',side_effect=run), patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='')):
                    if failure:
                        with self.assertRaises(subprocess.CalledProcessError): installer.install(ROOT,work)
                        self.assertEqual(config.read_bytes(),b'original config')
                        self.assertTrue((app/'old').exists())
                    else:
                        installer.install(ROOT,work)
                        self.assertTrue((app/'new').exists())
                    self.assertEqual(recording.read_bytes(),b'audio')
                    self.assertFalse(list(app.parent.glob('.vella-update-*')))

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Apple Silicon bootstrap')
    def test_piped_bootstrap_checks_hash_and_rejects_traversal(self):
        for mode in ('valid', 'default', 'bad-hash', 'traversal'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=pathlib.Path(directory); archive=root/'source.tar.gz'; marker=root/'dispatched'
                with tarfile.open(archive,'w:gz') as tar:
                    files={'vella/Package.swift':b'// fixture', 'vella/scripts/install_app.py':b'import os,pathlib; pathlib.Path(os.environ["TEST_MARKER"]).write_text("ok")'}
                    if mode=='traversal': files['../escaped']=b'bad'
                    for name,data in files.items():
                        item=tarfile.TarInfo(name);item.size=len(data);tar.addfile(item,io.BytesIO(data))
                bin=root/'bin';bin.mkdir();curl=bin/'curl'
                curl.write_text('#!/bin/bash\nfor arg in "$@"; do if [[ "$arg" == */SHA256SUMS ]]; then /bin/cp "$TEST_SUMS" "${@: -1}"; exit; fi; done\n/bin/cp "$TEST_ARCHIVE" "${@: -1}"\n');curl.chmod(0o755)
                env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],PYTHON=sys.executable,VELLA_SOURCE_URL='https://example.invalid/source.tar.gz',VELLA_SOURCE_SHA256='0'*64 if mode=='bad-hash' else hashlib.sha256(archive.read_bytes()).hexdigest(),TEST_ARCHIVE=str(archive),TEST_MARKER=str(marker))
                sums=root/'SHA256SUMS'; sums.write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  Vella-0.6.0-source.tar.gz\n')
                env['TEST_SUMS']=str(sums)
                if mode=='default':
                    env.pop('VELLA_SOURCE_URL'); env.pop('VELLA_SOURCE_SHA256')
                result=subprocess.run(['bash'],input=(ROOT/'scripts/install.sh').read_text(),env=env,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode==0,mode in ('valid','default'),result.stderr)
                self.assertEqual(marker.exists(),mode in ('valid','default'))

    def test_signed_installation_refused_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            app=pathlib.Path(directory)/'Vella.app'; app.mkdir()
            with patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}), patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='Authority=existing certificate')), patch.object(installer,'run') as run:
                with self.assertRaises(SystemExit): installer.install(ROOT,pathlib.Path(directory))
                run.assert_not_called()

    def test_symlink_destination_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); target=root/'target'; target.mkdir()
            app=root/'Vella.app'; app.symlink_to(target)
            with patch.dict(os.environ,{'VELLA_APP_PATH':str(app)}):
                with self.assertRaises(SystemExit): installer.install(ROOT,root)
