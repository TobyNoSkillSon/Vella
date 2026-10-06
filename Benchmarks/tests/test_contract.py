"""CPU-only failure checks for contribution arithmetic and pinned audio identity."""
import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('check_result', ROOT / 'check-result.py')
checks = importlib.util.module_from_spec(spec); spec.loader.exec_module(checks)
from fetch import verify
from run import public_status, check_selection, new_output
from gate import compare
import numpy as np
import soundfile as sf
import hashlib


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.example = json.loads((ROOT / 'result.example.json').read_text())

    def test_example_and_missing_energy(self):
        self.assertEqual(checks.check(self.example), 'example only; do not submit')
        broken = copy.deepcopy(self.example)
        broken['metrics']['energy_j_per_audio_minute'] = 0
        with self.assertRaises(AssertionError): checks.check(broken)

    def test_false_full_claim_and_speed_arithmetic(self):
        for mutate in [lambda r: r['suite'].update(quality_label='full'),
                       lambda r: r['passes'][0].update(speed_x_realtime=99),
                       lambda r: r['model']['status'].pop('fallbacks')]:
            broken = copy.deepcopy(self.example); mutate(broken)
            with self.assertRaises((AssertionError, KeyError)): checks.check(broken)

    def test_shipped_status_fallback_and_selection(self):
        payload = json.loads((ROOT / 'tests/fixtures/status-2.0.0.json').read_text())
        model = payload['models']['parakeet-v3-ultra']
        self.assertNotIn('recipe', model)
        self.assertNotIn('requested_selection', model)
        check_selection(model, 'bf16', 'Optimized', 'Fast')
        status = public_status(model)
        self.assertEqual(status['fallbacks'], ['self-test failed: encoder'])
        result = copy.deepcopy(self.example)
        result['model']['status'] = status
        checks.check(result)
        result['model']['status']['fallbacks'] = []
        with self.assertRaisesRegex(AssertionError, 'must record a fallback'): checks.check(result)
        for args in [('bf16', 'Standard', 'Fast'), ('int8', 'Optimized', 'Fast'), ('fp16', 'Optimized', 'Fast'), ('bf16', 'Optimized', 'Exact')]:
            with self.assertRaisesRegex(RuntimeError, 'does not match'): check_selection(model, *args)
        model.pop('engine_reason')
        with self.assertRaisesRegex(RuntimeError, 'without a fallback reason'): public_status(model)
        model['engine'] = 'optimized'
        self.assertEqual(public_status(model)['fallbacks'], [])
        model['engine_reason'] = 'nax_gemm disabled: unsupported GPU'
        self.assertEqual(public_status(model)['fallbacks'], [model['engine_reason']])

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'run'
            new_output(out)
            (out / 'keep').write_text('existing result')
            with self.assertRaisesRegex(ValueError, 'fresh --out'): new_output(out)
            self.assertEqual((out / 'keep').read_text(), 'existing result')

    def test_pcm_hash_sample_count_and_layout(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); pcm = np.array([0, 1, -1, 32767, -32768], dtype='<i2')
            sf.write(root / 'a.flac', pcm, 16000, subtype='PCM_16')
            c = {'id':'a','file':'a.flac','samples':len(pcm),'pcmSha256':hashlib.sha256(pcm.tobytes()).hexdigest()}
            np.testing.assert_array_equal(verify(c,root), pcm)
            c['pcmSha256'] = '0' * 64
            with self.assertRaises(ValueError): verify(c,root)
            c['pcmSha256'] = hashlib.sha256(pcm.tobytes()).hexdigest(); c['samples'] += 1
            with self.assertRaises(ValueError): verify(c,root)

    def test_gate_detects_lost_tail_even_with_identical_aggregate(self):
        base = {'modelID':'m','suiteID':'vella-v2','scoringVersion':'v','scorerSHA256':'s','clips':[{'id':'a'}],
                'words':{'rate':0},'formatting':{'rate':0},'multilingual':{'languages':{}}}
        manifest = {'clips':[{'id':'a','language':'en','reference':'one two three four five six'}]}
        standard = {'clips':[{'id':'a','transcript':'one two three four five six'}]}
        candidate = {'clips':[{'id':'a','transcript':'one two three'}]}
        self.assertFalse(compare(base,base,standard,candidate,manifest)['pass'])
        self.assertTrue(compare(base,base,standard,standard,manifest)['pass'])


if __name__ == '__main__': unittest.main()
