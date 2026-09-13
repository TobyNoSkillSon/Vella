import importlib.util
import pathlib
import plistlib
import re
import subprocess
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('toolchain_check', ROOT/'scripts/check_toolchain.py')
toolchain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(toolchain)


class ToolchainCheckTests(unittest.TestCase):
    def test_checks_package_manager_and_actual_state_fixture_with_deadlines(self):
        with patch.object(toolchain.subprocess, 'run') as run:
            toolchain.check()
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], ['xcrun', 'swift', 'package', '--version'])
        self.assertEqual(pathlib.Path(run.call_args_list[1].args[0][-1]).name, 'StateCompatibilityFixture.swift')
        self.assertTrue(all(c.kwargs['timeout'] > 0 for c in run.call_args_list))

    def test_incomplete_tools_fail_with_actionable_preservation_message(self):
        for error in (FileNotFoundError('xcrun'), subprocess.TimeoutExpired('swift', 30),
                      subprocess.CalledProcessError(-6, 'swift', stderr='Library mismatch')):
            with self.subTest(error=type(error).__name__), patch.object(toolchain.subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(SystemExit, 'existing Vella app has not been replaced'):
                    toolchain.check()

    def test_release_bootstrap_matches_bundle_version(self):
        version = re.search(r'^VERSION="([^"]+)"', (ROOT/'scripts/install.sh').read_text(), re.M).group(1)
        self.assertEqual(version, plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString'])


if __name__ == '__main__':
    unittest.main()
