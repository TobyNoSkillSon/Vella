import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BenchmarkSiteTests(unittest.TestCase):
    def test_only_full_current_runs_have_matching_interactive_values(self):
        payload = (ROOT / 'docs/data.js').read_text().removeprefix('const VELLA_RESULTS = ').strip().removesuffix(';')
        rows = json.loads(payload)['rows']
        catalogs = {}
        for catalog in ['models.json', 'streaming-models.json', 'Benchmarks/additional-models.json']:
            for model in json.loads((ROOT / 'Resources' / catalog).read_text()):
                catalogs[model['id']] = model
        indexed = {r['id']: r for r in rows}
        self.assertEqual(len(indexed), len(rows), 'Duplicate benchmark row IDs')
        policy = json.loads((ROOT / 'Resources/benchmark-policy.json').read_text())
        files = [p for p in (ROOT / 'Resources/ReferenceResults').glob('*.json')
                 if (r := json.loads(p.read_text()))['suiteID'] == policy['suiteID']
                 and r['suiteHash'] == policy['suiteHash'] and r['repeats'] >= policy['minimumRepeats']]
        self.assertTrue(files)
        self.assertEqual(set(indexed), {p.stem for p in files})
        self.assertNotIn('qualification-control', indexed)
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
                self.assertEqual(row['modelURL'], 'https://huggingface.co/' + catalogs[data['modelID']]['repository'])
                for field, key in [('text','formattedCharacterErrorRate'), ('punctuation','punctuationF1'), ('casing','capitalizationAccuracy')]:
                    value = data.get('formatting', {}).get(key)
                    self.assertEqual(row[field], value * 100 if value is not None else None)
                memory = data.get('runtimeMemoryMeasurement') or data.get('memoryMeasurement')
                self.assertEqual(row['ram'], (memory['runtimePeakMLXBytes'] if memory else data['peakMLXBytes']) / 1e9)
                self.assertEqual(row['memory'], 'Legacy peak' if not memory else 'Warm · timing run' if memory.get('measurementKind') == 'timing' else 'Warm · separate run')
