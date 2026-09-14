"""Isolated installer/download protocol tests: no Hub, packages, app or inference."""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT/'scripts/install_app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ENTRY = next(e for e in json.loads((ROOT/'Resources/models.json').read_text())
             if e['id'] == installer.DEFAULT_MODEL_ID)


class DefaultModelTests(unittest.TestCase):
    def test_runtime_config_seed_is_fresh_only(self):
        script = (ROOT/'scripts/setup-backend.sh').read_text()
        code = script.rsplit("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        for existing in (False, True):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                settings = {'model': '/external/dictation', 'streamingModel': '/shared/streaming',
                            'custom': 42, 'preferredMicrophone': 'fixture'}
                if existing: (root/'config.json').write_text(json.dumps(settings))
                original = (root/'config.json').read_bytes() if existing else None
                result = subprocess.run([sys.executable, '-B', '-', str(root), str(root/'runtime'), '--migrate-runtime'],
                                        input=code, text=True, capture_output=True, timeout=10,
                                        env=dict(os.environ, VELLA_INITIAL_MODEL='/verified/default'))
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = json.loads((root/'config.json').read_text())
                if existing:
                    for key, value in settings.items(): self.assertEqual(actual[key], value)
                    self.assertEqual((root/'config.before-runtime.json').read_bytes(), original)
                else:
                    self.assertEqual(actual['model'], '/verified/default')
                    self.assertFalse((root/'config.before-runtime.json').exists())

    def test_worker_protocol_and_validation(self):
        for failure in ('none', 'id', 'revision', 'path', 'exit', 'weights', 'quantization', 'timeout'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory); support = root/'support'
                destination = support/'Models'/ENTRY['id']; destination.mkdir(parents=True)
                config = {'model_type': 'parakeet', 'quantization': {'bits': 8 if failure == 'quantization' else 4}}
                (destination/'config.json').write_text(json.dumps(config))
                if failure != 'weights': (destination/'model.safetensors').write_bytes(b'fixture only')
                event = dict(event='installed', modelID=ENTRY['id'], revision=ENTRY['revision'], path=str(destination))
                if failure in ('id', 'revision', 'path'):
                    event[{'id': 'modelID', 'revision': 'revision', 'path': 'path'}[failure]] = 'wrong'
                script = root/'fake.py'
                script.write_text('import json,time,sys\n'
                                  + ('time.sleep(10)\n' if failure == 'timeout' else '')
                                  + 'print(json.dumps({"event":"progress","message":"Fixture download","completed":50,"total":100}),flush=True)\n'
                                  + f'print({json.dumps(event)!r},flush=True)\n'
                                  + f'sys.exit({1 if failure == "exit" else 0})\n')
                real_popen = subprocess.Popen
                calls = []
                def popen(args, **kwargs):
                    calls.append(args)
                    return real_popen([sys.executable, '-B', str(script)], **kwargs)
                with patch.object(installer.subprocess, 'Popen', side_effect=popen):
                    if failure == 'none':
                        result = installer.download_default(ROOT, support, sys.executable)
                        self.assertEqual(result['path'], str(destination))
                    else:
                        with self.assertRaises((ValueError, subprocess.SubprocessError)):
                            installer.download_default(ROOT, support, sys.executable, timeout=.1 if failure == 'timeout' else 5)
                self.assertEqual(calls[0][0:4], [sys.executable, '-B', str(ROOT/'Resources/benchmark_worker.py'), 'download'])
                self.assertFalse((support/'config.json').exists())
                self.assertFalse((support/'models-installed.json').exists())

    def test_fresh_install_failure_retry_and_swap_rollback(self):
        for failure in ('none', 'download', 'swap'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory); support = home/'Library/Application Support/Vella'
                work = home/'work'; work.mkdir(); app = home/'Applications/Vella.app'
                attempts = []
                state = {'failure': failure}
                def run(args, **kwargs):
                    if args[0].endswith('build.sh'):
                        staged = work/'Vella.app'; staged.mkdir(exist_ok=True); (staged/'new').write_text('new')
                    if args[-1] == '--migrate-runtime':
                        (support/'config.json').write_text(json.dumps({'model': kwargs['env']['VELLA_INITIAL_MODEL'], 'streamingModel': '', 'preferredMicrophone': 'fixture'}))
                    return subprocess.CompletedProcess(args, 0, stdout=f'Prepared Vella runtime: {sys.executable}\n' if args[-1] == '--runtime-only' else '')
                def download(source, target, python):
                    self.assertEqual(python, sys.executable)
                    attempts.append(1)
                    destination = target/'Models'/ENTRY['id']; destination.mkdir(parents=True, exist_ok=True)
                    (destination/'partial').write_bytes(b'resumable')
                    if state['failure'] == 'download': raise ValueError('fixture network failure')
                    return dict(path=str(destination), revision=ENTRY['revision'])
                original_rename = pathlib.Path.rename
                def rename(path, target):
                    if path.name == 'replacement.app' and state['failure'] == 'swap': raise OSError('fixture swap failure')
                    return original_rename(path, target)
                with patch.object(pathlib.Path, 'home', return_value=home), patch.dict(os.environ, VELLA_APP_PATH=str(app)), patch.object(installer, 'run', side_effect=run), patch.object(installer, 'download_default', side_effect=download), patch.object(pathlib.Path, 'rename', rename):
                    if failure != 'none':
                        with self.assertRaises((ValueError, OSError)): installer.install(ROOT, work)
                        self.assertFalse(app.exists())
                        self.assertFalse((support/'config.json').exists())
                        self.assertFalse((support/'models-installed.json').exists())
                        self.assertEqual((support/'Models'/ENTRY['id']/'partial').read_bytes(), b'resumable')
                        state['failure'] = 'none'
                    installer.install(ROOT, work)
                    self.assertTrue((app/'new').exists())
                    config = json.loads((support/'config.json').read_text())
                    self.assertEqual(config['model'], str(support/'Models'/ENTRY['id']))
                    self.assertEqual(config['streamingModel'], '')
                    self.assertEqual(config['preferredMicrophone'], 'fixture')
                    self.assertEqual(json.loads((support/'models-installed.json').read_text())[ENTRY['id']]['revision'], ENTRY['revision'])
                    self.assertEqual(len(attempts), 1 if failure == 'none' else 2)

    def test_existing_settings_or_registry_skip_bootstrap_without_app(self):
        for existing in ('config.json', 'models-installed.json'):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory); support = root/'support'; support.mkdir()
                data = {'model': '/external/dictation', 'streamingModel': '/shared/streaming', 'custom': 'preserved'} if existing == 'config.json' else {'external': {'path': '/shared/model'}}
                (support/existing).write_text(json.dumps(data))
                before = (support/existing).read_bytes()
                work = root/'work'; work.mkdir(); (work/'Vella.app').mkdir()
                app = root/'Applications/Vella.app'
                with patch.object(installer, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')), patch.object(installer, 'download_default') as download:
                    installer.install_locked(ROOT, work, support, app)
                    download.assert_not_called()
                self.assertEqual((support/existing).read_bytes(), before)

    def test_linked_and_shared_download_assets_rejected(self):
        for link in ('ancestor', 'file', 'hardlink'):
            with self.subTest(link=link), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory); support = root/'support'; support.mkdir()
                external = root/'external'; external.mkdir(); victim = external/'weights'; victim.write_bytes(b'keep')
                destination = support/'Models'/ENTRY['id']
                if link == 'ancestor': (support/'Models').symlink_to(external)
                else:
                    destination.mkdir(parents=True)
                    if link == 'file': (destination/'weights').symlink_to(victim)
                    else: os.link(victim, destination/'weights')
                with patch.object(installer.subprocess, 'Popen') as popen:
                    with self.assertRaises((ValueError, SystemExit)): installer.download_default(ROOT, support, sys.executable)
                    popen.assert_not_called()
                self.assertEqual(victim.read_bytes(), b'keep')


if __name__ == '__main__': unittest.main()
