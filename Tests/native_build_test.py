"""Swift-only build preparation with isolated output; never builds into dist or installs an app."""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class NativeBuildTests(unittest.TestCase):
    def test_reference_compaction_obeys_policy_and_omits_clip_transcripts(self):
        with tempfile.TemporaryDirectory(prefix='vella-native-reference-') as directory:
            result = subprocess.run(['xcrun', 'swift', 'scripts/prepare-build.swift', 'compact', directory],
                                    cwd=ROOT, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            policy = json.loads((ROOT/'Resources/benchmark-policy.json').read_text())
            expected = {}
            for file in (ROOT/'Resources/ReferenceResults').glob('*.json'):
                value = json.loads(file.read_text())
                if value['suiteID'] != policy['suiteID'] or value['suiteHash'] != policy['suiteHash'] or value['repeats'] < policy['minimumRepeats']: continue
                if value.get('formatting', {}).get('scorerSHA256') != policy['scorerSHA256']: continue
                if value.get('formatting', {}).get('lexicalNormalizerSHA256') != policy['lexicalNormalizerSHA256']: continue
                value['clips'] = []
                expected[file.name] = value
            actual = {file.name: json.loads(file.read_text()) for file in pathlib.Path(directory).glob('*.json')}
            self.assertEqual(actual, expected)

    def test_build_shell_has_no_python_execution_and_candidate_shells_parse(self):
        build = (ROOT/'scripts/build.sh').read_text()
        self.assertNotIn('${PYTHON', build)
        self.assertNotIn('check_toolchain.py', build)
        # The only allowed mention is deleting the stale file left by Python-era app bundles.
        mentions = [line for line in build.splitlines() if 'setup-backend.sh' in line]
        self.assertTrue(all(line.lstrip().startswith('rm -f ') for line in mentions), mentions)
        self.assertNotIn('cp scripts/setup-backend.sh', build)
        for file in ['scripts/build.sh', 'scripts/install-native.sh', 'docs/install-native.sh']:
            subprocess.run(['bash', '-n', str(ROOT/file)], check=True, timeout=5)


if __name__ == '__main__': unittest.main()
