import os
import pathlib
import subprocess
import sys
import platform
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/setup-backend.sh'

class SetupSafetyTests(unittest.TestCase):
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
