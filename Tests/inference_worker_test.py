import gc
import importlib.util
import io
import json
import pathlib
import subprocess
import signal
import sys
import tempfile
import unittest
import uuid
import wave
import weakref
from unittest.mock import patch

RESOURCES = pathlib.Path(__file__).resolve().parents[1] / 'Resources'
sys.path.insert(0, str(RESOURCES))
spec = importlib.util.spec_from_file_location('inference_worker', RESOURCES / 'inference_worker.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class MLX:
    def __init__(self): self.clears = 0
    def set_cache_limit(self, limit): self.limit = limit
    def synchronize(self): pass
    def reset_peak_memory(self): pass
    def get_peak_memory(self): return 123
    def get_active_memory(self): return 100
    def get_cache_memory(self): return 0
    def clear_cache(self): self.clears += 1


class Tests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'macOS physical-footprint metrics')
    def test_process_footprint_includes_native_lifetime_peak(self):
        metrics = w.process_memory()
        self.assertGreater(metrics['processFootprintBytes'], 0)
        self.assertGreaterEqual(metrics['processPeakFootprintBytes'], metrics['processFootprintBytes'])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.audio = self.root / 'sample.wav'
        with wave.open(str(self.audio), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\0\0' * 1600)
        self.paths = [self.root / 'one', self.root / 'two']
        for path in self.paths: path.mkdir()
        self.refs = []
        self.calls = []
        self.mx = MLX()
        calls = self.calls
        class Model:
            def generate(self, audio, verbose=True, max_tokens=0, chunk_duration=0, stream=True):
                calls.append((audio, verbose, max_tokens, chunk_duration, stream))
                return {'text': ' Intended text. '}
        def load(path):
            self.assertFalse(any(ref() is not None for ref in self.refs))
            model = Model()
            self.refs.append(weakref.ref(model))
            return model
        self.worker = w.Worker(self.mx, load, lambda path: path)

    def request(self, index=0, **values):
        return dict(id=str(uuid.uuid4()), model=str(self.paths[index]), audio=str(self.audio), **values)

    def test_repeated_requests_and_one_model_residency(self):
        first = self.worker.handle(self.request())
        for _ in range(5):
            response = self.worker.handle(self.request())
            self.assertFalse(response['metrics']['modelLoaded'])
            self.assertEqual(response['metrics']['mlxPeakPhase'], 'warm_request')
        self.assertEqual(first['text'], 'Intended text.')
        self.assertTrue(first['metrics']['modelLoaded'])
        self.assertEqual(len(self.refs), 1)
        self.worker.handle(self.request(1))
        self.assertEqual(len(self.refs), 2)
        self.assertIsNone(self.refs[0]())
        self.assertEqual(self.mx.limit, 64 * 1024 * 1024)
        self.assertEqual(self.calls[0][1:], (False, 1024, 30.0, False))
        self.worker.release()
        self.assertIsNone(self.refs[1]())

    def test_generator_signature_text_and_cleanup(self):
        closed = []
        class Model:
            def generate(self, audio, verbose=True):
                self.verbose = verbose
                try:
                    yield {'text': 'One '}
                    yield type('Result', (), {'text': 'two'})()
                finally: closed.append(True)
        self.worker.loader = lambda path: Model()
        result = self.worker.handle(self.request())
        self.assertEqual(result['text'], 'One two')
        self.assertEqual(closed, [True])
        self.assertFalse(self.worker.model.verbose)

    def test_failure_drops_model_and_traceback_tensors(self):
        refs = []
        class Tensor: pass
        class Model:
            def generate(self, audio):
                tensor = Tensor()
                refs.append(weakref.ref(tensor))
                yield {'text': 'PRIVATE SPEECH'}
                raise RuntimeError('PRIVATE SPEECH out of memory')
        self.worker.loader = lambda path: Model()
        before = self.mx.clears
        result = self.worker.handle(self.request())
        self.assertEqual(result['error']['code'], 'memory')
        self.assertNotIn('PRIVATE', json.dumps(result))
        self.assertIsNone(self.worker.model)
        self.assertIsNone(refs[0]())
        self.assertGreater(self.mx.clears, before)
        self.worker.loader = lambda path: type('Model', (), {'generate': lambda self, audio: 'recovered'})()
        self.assertEqual(self.worker.handle(self.request())['text'], 'recovered')

    def test_empty_and_inference_failure_are_sanitized(self):
        class Empty:
            def generate(self, audio): return {'text': '  '}
        self.worker.loader = lambda path: Empty()
        result = self.worker.handle(self.request())
        self.assertEqual(result['text'], '')
        self.assertIn('metrics', result)
        self.assertNotIn('error', result)
        self.worker.release()
        def fail(path): raise RuntimeError('SECRET SPEECH')
        self.worker.loader = fail
        result = self.worker.handle(self.request())
        self.assertEqual(result['error']['code'], 'inference')
        self.assertNotIn('SECRET', json.dumps(result))

    def test_malformed_model_output_is_not_empty_success(self):
        for value in (None, {}, {'text': None}, {'text': 42}):
            self.worker.release()
            self.worker.loader = lambda path: type('Bad', (), {'generate': lambda self, audio: value})()
            self.assertEqual(self.worker.handle(self.request())['error']['code'], 'inference')

    def test_invalid_protocol_and_paths_do_not_load(self):
        requests = [None, [], {}, self.request(operation='shutdown')]
        for key, value in [('id', 'wrong'), ('model', 'repo/model'), ('audio', 'relative.wav'),
                           ('audio', str(self.root)), ('model', '/does-not-exist')]:
            request = self.request(); request[key] = value; requests.append(request)
        for request in requests:
            self.assertEqual(self.worker.handle(request)['error']['code'], 'invalid')
        self.assertEqual(self.refs, [])

    def test_admission_rejected_before_load(self):
        def reject(path): raise ValueError('PRIVATE')
        self.worker.admission = reject
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')
        self.assertEqual(self.refs, [])

    def test_real_admission_rejects_custom_code(self):
        from calibration_worker import validate_local
        folder = self.paths[0]
        (folder / 'config.json').write_text('{"model_type":"parakeet"}')
        (folder / 'model.safetensors').write_bytes(b'fake')
        self.assertEqual(validate_local(folder), folder.resolve())
        (folder / 'tokenizer_config.json').write_text('{"auto_map":{"x":"custom"}}')
        self.worker.admission = validate_local
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')

    def test_bounded_lines_and_eof(self):
        source = io.BytesIO(b'x' * (w.MAX_LINE * 3) + b'\n{bad json}\n' +
                            json.dumps(self.request()).encode() + b'\n')
        output = io.StringIO()
        w.serve(self.worker, source, output)
        rows = [json.loads(row) for row in output.getvalue().splitlines()]
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]['error']['code'], 'invalid')
        self.assertEqual(rows[1]['error']['code'], 'invalid')
        self.assertEqual(rows[2]['text'], 'Intended text.')
        blank = io.StringIO()
        w.serve(self.worker, io.BytesIO(), blank)
        self.assertEqual(blank.getvalue(), '')

    def test_deadline_armed_per_request_and_disarmed_before_idle(self):
        alarms = []
        owner = self
        class Source(io.BytesIO):
            def readline(self, limit):
                owner.assertEqual(alarms[-1], 0)
                return super().readline(limit)
        source = Source((json.dumps(self.request()) + '\n').encode() * 2)
        with patch.object(w.signal, 'signal') as handler, patch.object(
                w.signal, 'alarm', side_effect=alarms.append):
            w.serve(self.worker, source, io.StringIO())
        handler.assert_called_once_with(signal.SIGALRM, signal.SIG_DFL)
        self.assertEqual(alarms, [0, 120, 0, 120, 0])

    def test_deadline_cleared_on_request_exception(self):
        with patch.object(self.worker, 'handle', side_effect=RuntimeError()), patch.object(
                w.signal, 'signal'), patch.object(w.signal, 'alarm') as alarm:
            with self.assertRaises(RuntimeError):
                w.serve(self.worker, io.BytesIO(b'{}\n'), io.StringIO())
        self.assertEqual([call.args[0] for call in alarm.call_args_list], [0, 120, 0])

    def test_deadline_terminates_native_call_holding_gil(self):
        code = r"""
import ctypes, io, sys
sys.path.insert(0, sys.argv[1])
import inference_worker as w
w.REQUEST_SECONDS = 1
class Worker:
    def handle(self, request):
        ctypes.PyDLL(None).sleep(30)
w.serve(Worker(), io.BytesIO(b'{}\n'), io.StringIO())
"""
        result = subprocess.run([sys.executable, '-B', '-c', code, str(RESOURCES)],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, -signal.SIGALRM)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'')

    def test_main_suppresses_python_and_native_diagnostics(self):
        code = r"""
import os, sys, types
sys.path.insert(0, sys.argv[1])
import inference_worker as w
mx = types.ModuleType('mlx.core')
for name in ('synchronize', 'clear_cache', 'reset_peak_memory'):
    setattr(mx, name, lambda: None)
for name in ('get_peak_memory', 'get_active_memory', 'get_cache_memory'):
    setattr(mx, name, lambda: 0)
mx.set_cache_limit = lambda value: None
sys.modules['mlx'] = types.ModuleType('mlx')
sys.modules['mlx.core'] = mx
utils = types.ModuleType('mlx_audio.stt.utils')
class Model:
    def generate(self, audio, verbose=False):
        print('PRIVATE diagnostic speech')
        print('PRIVATE stderr speech', file=sys.stderr)
        os.write(1, b'PRIVATE native speech\n')
        os.write(2, b'PRIVATE native error\n')
        return {'text': 'Intended response'}
utils.load_model = lambda path: Model()
for name in ('mlx_audio', 'mlx_audio.stt'):
    sys.modules[name] = types.ModuleType(name)
sys.modules['mlx_audio.stt.utils'] = utils
admission = types.ModuleType('calibration_worker')
admission.validate_local = lambda path: path
sys.modules['calibration_worker'] = admission
w.main()
"""
        result = subprocess.run([sys.executable, '-B', '-c', code, str(RESOURCES)],
                                input=json.dumps(self.request()) + '\n', text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertNotIn('PRIVATE', result.stdout)
        self.assertEqual(json.loads(result.stdout)['text'], 'Intended response')

    def test_load_failure_releases_traceback_before_cleanup(self):
        refs = []
        class Tensor: pass
        def load(path):
            tensor = Tensor()
            refs.append(weakref.ref(tensor))
            raise MemoryError('PRIVATE speech')
        self.worker.loader = load
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'memory')
        self.assertIsNone(refs[0]())
        self.assertIsNone(self.worker.model)

    def test_audio_bounds_and_truncation(self):
        for rate, channels, width, frames in [(8000, 1, 2, 100), (16000, 2, 2, 100),
                                              (16000, 1, 1, 100), (16000, 1, 2, 480001),
                                              (16000, 1, 2, 0)]:
            with wave.open(str(self.audio), 'wb') as audio:
                audio.setparams((channels, width, rate, 0, 'NONE', 'NONE'))
                audio.writeframes(b'\0' * frames * width * channels)
            self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')
        self.audio.write_bytes(b'x' * (w.MAX_AUDIO + 1))
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')
        with wave.open(str(self.audio), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\0\0' * 100)
        self.audio.write_bytes(self.audio.read_bytes()[:-10])
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')
        self.audio.write_bytes(b'not WAV')
        self.assertEqual(self.worker.handle(self.request())['error']['code'], 'invalid')


if __name__ == '__main__': unittest.main()
