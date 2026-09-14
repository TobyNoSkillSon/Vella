import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BenchmarkSiteTests(unittest.TestCase):
    def test_every_published_run_has_matching_interactive_values(self):
        payload = (ROOT / 'docs/data.js').read_text().removeprefix('const VELLA_RESULTS = ').strip().removesuffix(';')
        rows = json.loads(payload)['rows']
        indexed = {r['id']: r for r in rows}
        self.assertEqual(len(indexed), len(rows), 'Duplicate benchmark row IDs')
        files = list((ROOT / 'Resources/ReferenceResults').glob('*.json'))
        self.assertEqual(set(indexed), {p.stem for p in files} | {'qualification-control'})
        for path in files:
            with self.subTest(record=path.name):
                data = json.loads(path.read_text()); row = indexed[path.stem]
                self.assertEqual(row['words'], data['wordErrorRate'] * 100)
                self.assertEqual(row['speed'], data['realtimeFactor'])
                self.assertEqual(row['seconds'], data['transcriptionSeconds'])
                self.assertEqual(row['quantization'], data['quantization'])
                self.assertEqual(row['mode'], 'Streaming' if data.get('recognitionMode') == 'streaming' else 'Batch')
                self.assertEqual(row['date'], data['measuredAt'][:10])
                self.assertTrue(row['source'].endswith('/Resources/ReferenceResults/' + path.name))
                for field, key in [('text','formattedCharacterErrorRate'), ('punctuation','punctuationF1'), ('casing','capitalizationAccuracy')]:
                    value = data.get('formatting', {}).get(key)
                    self.assertEqual(row[field], value * 100 if value is not None else None)
                memory = data.get('runtimeMemoryMeasurement') or data.get('memoryMeasurement')
                self.assertEqual(row['ram'], (memory['runtimePeakMLXBytes'] if memory else data['peakMLXBytes']) / 1e9)
                self.assertEqual(row['memory'], 'Legacy peak' if not memory else 'Warm · timing run' if memory.get('measurementKind') == 'timing' else 'Warm · separate run')
        control = json.loads((ROOT / 'Resources/Benchmarks/qualification-2026-09-12.json').read_text())['control']
        row = indexed['qualification-control']
        self.assertEqual(row['speed'], control['rerunRealtimeFactor'])
        self.assertEqual(row['words'], control['wordErrorRate'] * 100)
        self.assertEqual(row['text'], control['formattedCharacterErrorRate'] * 100)
        for key in ['ram', 'seconds', 'punctuation', 'casing']:
            self.assertIsNone(row[key], 'Do not borrow unreported control metrics')
