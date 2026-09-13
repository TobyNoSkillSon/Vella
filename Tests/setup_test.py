import os
import pathlib
import subprocess
import sys
import platform
import hashlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/setup-backend.sh'

class SetupSafetyTests(unittest.TestCase):
    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and (3, 12) <= sys.version_info[:2] < (3, 15), 'compatible local Python')
    def test_linked_runtime_and_configuration_are_preserved_before_setup(self):
        lock = SCRIPT.parent.parent / 'Resources/runtime-requirements.txt'
        digest = hashlib.sha256(lock.read_bytes()).hexdigest()[:12]
        runtime = f'Runtimes/mlx-audio-0.5.1-mlx-0.32.2-{digest}-python-{sys.version_info.major}.{sys.version_info.minor}'
        for relative in ('Runtimes', runtime, runtime+'/.vella-ready', 'config.json',
                         'config.before-runtime.json', 'config.runtime-pending.json'):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as folder:
                base = pathlib.Path(folder); root = base/'support'; root.mkdir()
                external = base/'external'; external.write_bytes(b'preserve')
                link = root/relative; link.parent.mkdir(parents=True, exist_ok=True); link.symlink_to(external)
                shim = base/'python-shim'
                shim.write_text('#!/bin/bash\nif [[ "$1" == -m && "$2" == venv ]]; then echo "Unexpected venv creation" >&2; exit 90; fi\nexec "$TEST_REAL_PYTHON" "$@"\n')
                shim.chmod(0o700)
                result = subprocess.run([str(SCRIPT), '--runtime-only'], env=dict(os.environ,
                    VELLA_SUPPORT_DIR=str(root), PYTHON=str(shim), TEST_REAL_PYTHON=sys.executable),
                    capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Linked runtime or configuration preserved', result.stderr)
                self.assertTrue(link.is_symlink())
                self.assertEqual(external.read_bytes(), b'preserve')

    def test_existing_configuration_prevents_downloads_and_runtime_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            config = root / 'config.json'
            config.write_text('{"keep":"existing configuration"}')
            before = config.read_bytes()
            env = dict(os.environ, VELLA_SUPPORT_DIR=folder, PYTHON='/nonexistent-python')
            result = subprocess.run([str(SCRIPT)], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(config.read_bytes(), before)
            self.assertEqual(list(root.iterdir()), [config])

    def test_missing_python_leaves_support_untouched(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder) / 'not-created'
            result = subprocess.run([str(SCRIPT)], env=dict(os.environ, VELLA_SUPPORT_DIR=str(root), PYTHON='/nonexistent-python'), capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Python 3.12', result.stderr)
            self.assertFalse(root.exists())

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and (3, 12) <= sys.version_info[:2] < (3, 15), 'compatible local Python')
    def test_busy_dictation_blocks_runtime_preparation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            state = root / 'dictation-status.json'
            state.write_text('{"phase":"recording"}')
            result = subprocess.run([str(SCRIPT), '--runtime-only'], env=dict(os.environ, VELLA_SUPPORT_DIR=folder, PYTHON=sys.executable), capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Finish dictation', result.stderr)
            self.assertEqual(list(root.iterdir()), [state])
