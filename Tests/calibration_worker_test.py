import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import sys
from unittest.mock import patch

RESOURCES = pathlib.Path(__file__).resolve().parents[1] / 'Resources'
sys.path.insert(0, str(RESOURCES))
spec = importlib.util.spec_from_file_location('calibration_worker', RESOURCES / 'calibration_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class CalibrationTests(unittest.TestCase):
    def test_pinned_licensed_sample(self):
        audio, seconds = worker.sample(RESOURCES / 'Calibration')
        self.assertAlmostEqual(seconds, 7.04)
        self.assertLess(audio.stat().st_size, 300000)

    def test_tampered_sample_rejected(self):
        import shutil
        with tempfile.TemporaryDirectory() as temp:
            folder = pathlib.Path(temp) / 'sample'
            shutil.copytree(RESOURCES / 'Calibration', folder)
            (folder / 'speech.wav').write_bytes(b'not audio')
            with self.assertRaises(ValueError):
                worker.sample(folder)

    def test_load_and_first_request_excluded_from_two_warm_repeats(self):
        class Model:
            calls = []
            def generate(self, path, max_tokens=None, chunk_duration=None, stream=None):
                self.calls.append((path, max_tokens, chunk_duration, stream))
                yield {'text': 'Synthetic calibration speech.'}
        model = Model()
        times = iter([0, 20, 21, 23, 24, 28])
        sync = []
        with contextlib.redirect_stdout(io.StringIO()):
            result = worker.measure(model, 'synthetic.wav', 8, lambda: sync.append(1), lambda: next(times))
        self.assertEqual(result['firstRequestSeconds'], 20)
        self.assertEqual(result['warmSeconds'], [2, 4])
        self.assertAlmostEqual(result['speed'], 8 / 3)
        self.assertEqual(len(model.calls), 3)
        self.assertEqual(model.calls[0][1:], (1024, 30.0, False))
        self.assertEqual(len(sync), 6)
        self.assertNotIn('transcript', json.dumps(result))

    def test_invalid_timing_rejected(self):
        class Model:
            def generate(self, path): return object()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
            worker.measure(Model(), 'sample', 8, lambda: None, lambda: 1)

    def test_empty_inference_is_not_a_fast_calibration(self):
        class Model:
            def generate(self, path): return {'text': ''}
        times = iter([0, 1])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'usable speech'):
            worker.measure(Model(), 'sample', 8, lambda: None, lambda: next(times))

    def test_only_local_builtin_models_admitted(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = pathlib.Path(temp)
            config = folder / 'config.json'
            config.write_text(json.dumps(dict(model_type='whisper', quantization=dict(bits=4))))
            (folder / 'model.safetensors').write_bytes(b'fake')
            self.assertEqual(worker.validate_local(folder), folder.resolve())
            config.write_text(json.dumps(dict(model_type='unknown')))
            with self.assertRaises(ValueError): worker.validate_local(folder)
            config.write_text(json.dumps(dict(model_type='whisper', auto_map={'x': 'unsafe'})))
            with self.assertRaises(ValueError): worker.validate_local(folder)
            config.write_text(json.dumps(dict(model_type='whisper')))
            (folder / 'tokenizer_config.json').write_text('{"auto_map":{"x":"unsafe"}}')
            with self.assertRaises(ValueError): worker.validate_local(folder)
            (folder / 'tokenizer_config.json').unlink()
            (folder / 'custom.py').write_text('')
            with self.assertRaises(ValueError): worker.validate_local(folder)

    def test_missing_folder_does_not_resolve_hub(self):
        with self.assertRaises(FileNotFoundError): worker.validate_local('/nonexistent/vella-calibration-model')


if __name__ == '__main__':
    unittest.main()
