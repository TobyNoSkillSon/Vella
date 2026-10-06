"""Fetch failures must expose every source while preserving pinned PCM identity."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fetch


class FetchTest(unittest.TestCase):
    def run_fetch(self, mode, args=('--yes',)):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'suites/v2').mkdir(parents=True)
            (root / 'suites/v2-quick').mkdir(parents=True)
            pcm = np.array([0, 1, -1], dtype='<i2')
            clips = []
            for identifier, allocation in [('a', 'first'), ('b', 'first'), ('c', 'last')]:
                clips.append(dict(id=identifier, allocation=allocation, file=identifier + '.flac',
                                  samples=len(pcm), pcmSha256=fetch.C.pcm_sha(pcm), key=identifier,
                                  language='en', duration=1, reference='words', referenceType='normalised',
                                  group=identifier, speaker=None, conditions=[], stratum='', origin={}, extra={}))
            manifest = dict(id='fixture', clips=clips)
            (root / 'suites/v2-quick/manifest.json').write_text(json.dumps(manifest))
            (root / 'suites/v2/suite.json').write_text(json.dumps(dict(allocations=[
                dict(id=allocation, source=allocation) for allocation in ('first', 'last')])))
            data = root / 'audio'
            if mode == 'cached':
                fetch.C.write_flac(data / 'a.flac', pcm + 1)
            attempted = []

            def prepare(ctx, candidates):
                if mode == 'prepare' and ctx.allocation == 'first':
                    raise ValueError('upstream unavailable')

            def extract(ctx, candidate):
                attempted.append(candidate.key)
                if mode == 'extract' and candidate.key == 'a':
                    raise ValueError('source audio checksum mismatch')
                samples = pcm.astype(float) / 32767
                if mode == 'pcm' and candidate.key == 'a':
                    samples += 0.1
                return samples, 16000, 'mean'

            adapter = SimpleNamespace(prepare=prepare, extract=extract)
            output = io.StringIO()
            with patch.object(fetch, 'ROOT', root), patch.object(sys, 'argv', [
                'fetch.py', '--audio-root', str(data), '--cache', str(root / 'cache'), *args
            ]), patch.object(fetch.importlib, 'import_module', return_value=adapter), contextlib.redirect_stdout(output):
                result = fetch.main()
            exists = (data / 'a.flac').exists()
            return result, output.getvalue(), attempted, exists

    def test_preparation_failure_continues_to_next_source(self):
        result, output, attempted, _ = self.run_fetch('prepare')
        self.assertEqual(result, 1)
        self.assertEqual(attempted, ['c'])
        self.assertIn('first (first): 0 verified, 2 failed', output)
        self.assertIn('last (last): 1 verified, 0 failed', output)
        self.assertIn('INCOMPLETE', output)
        self.assertNotIn('fixture: 3 clips verified', output)

    def test_extraction_failure_continues_with_same_and_next_source(self):
        result, output, attempted, exists = self.run_fetch('extract')
        self.assertEqual(result, 1)
        self.assertEqual(attempted, ['a', 'b', 'c'])
        self.assertFalse(exists)
        self.assertIn('first (first): 1 verified, 1 failed', output)
        self.assertIn('last (last): 1 verified, 0 failed', output)

    def test_pcm_mismatch_is_not_written_or_accepted(self):
        result, output, attempted, exists = self.run_fetch('pcm')
        self.assertEqual(result, 1)
        self.assertFalse(exists)
        self.assertEqual(attempted, ['a', 'b', 'c'])
        self.assertIn('upstream PCM mismatch: a', output)

    def test_invalid_cached_audio_does_not_hide_remaining_sources(self):
        result, output, attempted, exists = self.run_fetch('cached')
        self.assertEqual(result, 1)
        self.assertTrue(exists)
        self.assertEqual(attempted, ['b', 'c'])
        self.assertIn('PCM identity mismatch: a', output)
        self.assertIn('last (last): 1 verified, 0 failed', output)

    def test_missing_audio_without_downloads_reports_all_sources(self):
        for args in [('--verify-only',), ()]:
            with self.subTest(args=args):
                result, output, attempted, _ = self.run_fetch('success', args)
                self.assertEqual(result, 1)
                self.assertEqual(attempted, [])
                self.assertIn('first (first): 0 verified, 2 failed', output)
                self.assertIn('last (last): 0 verified, 1 failed', output)

    def test_complete_suite_returns_success(self):
        result, output, attempted, exists = self.run_fetch('success')
        self.assertEqual(result, 0)
        self.assertTrue(exists)
        self.assertEqual(attempted, ['a', 'b', 'c'])
        self.assertIn('fixture: 3 clips verified', output)
        self.assertNotIn('INCOMPLETE', output)


if __name__ == '__main__':
    unittest.main()
