#!/usr/bin/env python3
"""Structural checks for benchmark v2 (no audio needed) plus its scorer unit tests."""
import json, pathlib, re, sys, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUITE = ROOT / 'Resources/Benchmarks/v2'
sys.path.insert(0, str(SUITE / 'tests'))
from test_scoring import *  # noqa: E402,F401,F403  scorer unit tests


class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads((SUITE / 'suite.json').read_text())
        cls.manifest = json.loads((SUITE / 'manifest.json').read_text())

    def test_complete_and_unique(self):
        m = self.manifest
        self.assertEqual(m['incomplete'], [])
        ids = [c['id'] for c in m['clips']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual({c['allocation'] for c in m['clips']}, {a['id'] for a in self.plan['allocations']})

    def test_clip_fields(self):
        languages = {'en', 'pl', 'de', 'fr', 'es', 'sv', 'tr', 'ja', 'zh', 'ko'}
        for c in self.manifest['clips']:
            self.assertRegex(c['sha256'], r'^[0-9a-f]{64}$')
            self.assertRegex(c['pcmSha256'], r'^[0-9a-f]{64}$')
            self.assertIn(c['language'], languages)
            self.assertTrue(c['reference'].strip(), c['id'])
            self.assertNotRegex(c['reference'], r'IGNORE_TIME_SEGMENT|<[^>]*>|\[[^\]]*\]', c['id'])
            self.assertLessEqual(abs(c['samples'] - c['duration'] * 16000), 1, c['id'])
            self.assertTrue(c['file'].startswith(f"audio/{c['allocation']}/"), c['id'])
            self.assertTrue(c['group'], c['id'])
            if c['language'] == 'en':
                self.assertIn('words', c['tracks'])
            else:
                self.assertEqual(c['tracks'], ['multilingual'])
            if 'formatting' in c['tracks']:
                self.assertEqual(c['referenceType'], 'formatted', c['id'])

    def test_mix(self):
        s = self.manifest['summary']
        total = s['englishMinutes'] + s['nonEnglishMinutes']
        self.assertGreater(total, 225); self.assertLess(total, 255)
        self.assertAlmostEqual(s['englishMinutes'] / total, 0.70, delta=0.03)
        for a in self.plan['allocations']:
            got = s['perAllocationMinutes'][a['id']]
            self.assertLess(abs(got - a['minutes']) / a['minutes'], 0.08, a['id'])

    def test_sources_pinned_and_licensed(self):
        for s in self.manifest['sources'].values():
            for key in ('licence', 'licenceUrl', 'url', 'revision', 'attribution'):
                self.assertTrue(s.get(key), f"{s['id']} missing {key}")
            self.assertIsInstance(s['redistributable'], bool)
        for c in self.manifest['clips']:
            rev = json.dumps(c['origin'])
            self.assertNotRegex(rev, r'"revision": "main"', c['id'])


if __name__ == '__main__':
    unittest.main()
