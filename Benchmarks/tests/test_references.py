"""Reference loading, licensing boundaries and historical receipt identity; no network/model."""
import copy
import importlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import references as refs


class ReferencesTest(unittest.TestCase):
    def fixture(self):
        values = {'reference': 'Cafe\u0301  original', 'lexicalReference': 'café original'}
        clip = {'id': 'test', 'source': 'polish-tedx', 'key': 'test',
                **{k + 'Sha256': refs.text_sha(v) for k, v in values.items()}}
        return {'clips': [clip]}, values

    def test_fetch_cache_and_local_only_read_preserve_exact_bytes(self):
        manifest, values = self.fixture()
        before = copy.deepcopy(manifest)
        adapter = SimpleNamespace(references=lambda ctx, clip: values)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.dict(sys.modules, {'common': SimpleNamespace(Context=lambda *a: None)}), \
                 patch.object(importlib, 'import_module', return_value=adapter) as fetcher:
                fetched = refs.hydrate_references(manifest, root, fetch=True)
                self.assertEqual(fetched['clips'][0]['reference'], values['reference'])
                self.assertEqual(refs.hydrate_references(manifest, root), fetched)
                self.assertEqual(fetcher.call_count, 1)
            self.assertEqual(manifest, before)

    def test_missing_or_tampered_reference_fails_closed_without_fetch(self):
        manifest, values = self.fixture()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(importlib, 'import_module', side_effect=AssertionError('network forbidden')):
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'reference missing'):
                refs.hydrate_references(manifest, root)
            path = root / 'polish-tedx' / (manifest['clips'][0]['referenceSha256'] + '.json')
            path.parent.mkdir()
            for field in values:
                broken = {**values, field: 'changed'}
                path.write_text(json.dumps(broken))
                with self.assertRaisesRegex(ValueError, field + ' identity mismatch'):
                    refs.hydrate_references(manifest, root)

    def test_mismatched_upstream_is_never_cached(self):
        manifest, _ = self.fixture()
        adapter = SimpleNamespace(references=lambda *a: {'reference': 'changed'})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.dict(sys.modules, {'common': SimpleNamespace(Context=lambda *a: None)}), \
                 patch.object(importlib, 'import_module', return_value=adapter), \
                 self.assertRaisesRegex(ValueError, 'reference identity mismatch'):
                refs.hydrate_references(manifest, root, fetch=True)
            self.assertEqual(list(root.iterdir()), [])

    def test_hash_cannot_escape_cache(self):
        manifest, _ = self.fixture()
        manifest['clips'][0]['referenceSha256'] = '../outside'
        with self.assertRaisesRegex(ValueError, 'invalid reference hash'):
            refs.hydrate_references(manifest)

    def test_only_exact_historical_or_current_receipt_pairs_are_accepted(self):
        manifest = {'publishedIdentity': {'manifestSha256': 'old-manifest', 'scorerSha256': 'old-scorer'}}
        for manifest_sha, scorer_sha, accepted in [
            ('old-manifest', 'old-scorer', True), ('current-manifest', 'current-scorer', True),
            ('old-manifest', 'current-scorer', False), ('current-manifest', 'old-scorer', False),
            ('unknown', 'old-scorer', False)
        ]:
            self.assertEqual(refs.receipt_matches(manifest, manifest_sha, scorer_sha,
                'current-manifest', 'current-scorer'), accepted)

    def test_public_suites_contain_hashes_without_restricted_text(self):
        full = json.loads((ROOT / 'suites/v2/manifest.json').read_text())
        quick = json.loads((ROOT / 'suites/v2-quick/manifest.json').read_text())
        self.assertEqual((len(full['clips']), len(quick['clips'])), (797, 122))
        by_id = {c['id']: c for c in full['clips']}
        for clip in quick['clips']:
            self.assertEqual(clip, by_id[clip['id']])
        for manifest in (full, quick):
            for clip in manifest['clips']:
                if clip['source'] in refs.FETCHERS:
                    self.assertNotIn('reference', clip)
                    self.assertNotIn('lexicalReference', clip)
                    self.assertRegex(clip['referenceSha256'], r'^[0-9a-f]{64}$')
                    if clip['source'] == 'polish-tedx':
                        self.assertRegex(clip['lexicalReferenceSha256'], r'^[0-9a-f]{64}$')
                else:
                    self.assertIn('reference', clip)


if __name__ == '__main__':
    unittest.main()
