import base64
import importlib.util
import json
import os
from pathlib import Path
import struct
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import codecs
from types import SimpleNamespace
from unittest.mock import patch
import weakref

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('streaming_worker', ROOT / 'Resources/streaming_worker.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


def request(op, **kwargs):
    return dict(id=str(uuid.uuid4()), op=op, **kwargs)


def audio(samples):
    return request('audio', pcm=base64.b64encode(struct.pack('<' + 'f'*len(samples), *samples)).decode())


class Fake:
    drain = w.Native.drain
    def __init__(self, path=None):
        self.calls = []
        self.resets = 0
        self.text = ''
    def push(self, samples, final=False):
        self.calls.append((tuple(samples), final))
        if samples and any(samples):
            self.text = 'A complete prefix and suffix.'
    def reset(self):
        self.resets += 1
        self.text = ''
    def close(self):
        pass


class StreamingTests(unittest.TestCase):
    def session(self):
        s = w.Session(Fake)
        s.native = Fake()
        return s

    def test_silence_no_inference(self):
        s = self.session()
        for _ in range(100):
            r = s.handle(audio([0.0]*1600))
        self.assertEqual(r['frames'], 160000)
        self.assertEqual(s.native.calls, [])
        self.assertLessEqual(len(s.preroll), w.PRE_ROLL)
        self.assertEqual(s.handle(request('finish'))['committed'], '')
        self.assertEqual(s.native.calls, [])

    def test_empty_nonquiet_endpoint_succeeds_and_keeps_later_words(self):
        s = self.session()
        original = s.native.push
        s.native.push = lambda samples, final=False: None
        for _ in range(4):
            s.handle(audio([0.2]*1600))
        replies = [s.handle(audio([0.0]*1600)) for _ in range(8)]
        self.assertTrue(all(not r.get('incomplete', False) for r in replies))
        self.assertTrue(all(r['committed'] == '' for r in replies))
        self.assertEqual(s.native.resets, 1)
        s.native.push = original
        s.handle(audio([0.2]*1600))
        final = s.handle(request('finish'))
        self.assertFalse(final.get('incomplete', False))
        self.assertTrue(final['done'])
        self.assertEqual(final['committed'], 'A complete prefix and suffix.')

    def test_empty_nonquiet_finish_succeeds_without_retry_or_marker(self):
        s = self.session()
        def push(samples, final=False):
            s.native.calls.append((tuple(samples), final))
        s.native.push = push
        for _ in range(4):
            s.handle(audio([0.2]*1600))
        final = s.handle(request('finish'))
        self.assertEqual(final['frames'], 6400)
        self.assertEqual(final['committed'], '')
        self.assertEqual(final['partial'], '')
        self.assertTrue(final['done'])
        self.assertFalse(final.get('incomplete', False))
        self.assertEqual(sum(len(samples) for samples, _ in s.native.calls), 6400)
        self.assertEqual(sum(final for _, final in s.native.calls), 1)
        self.assertEqual(s.native.resets, 1)

    def test_native_finish_failure_is_not_empty_success(self):
        s = self.session()
        def push(samples, final=False):
            if final:
                raise RuntimeError('Native stream failed to finish')
        s.native.push = push
        s.handle(audio([0.2]*1600))
        with self.assertRaisesRegex(RuntimeError, 'failed to finish'):
            s.handle(request('finish'))
        self.assertFalse(s.done)

    def test_framing_and_endpoint(self):
        signal = [0.0]*6400 + [0.2]*6400 + [0.0]*16000
        outcomes = []
        for size in (1, 319, 320, 777, 1600):
            s = self.session()
            commits = []
            for i in range(0, len(signal), size):
                r = s.handle(audio(signal[i:i+size]))
                if r['committed']:
                    commits.append(r['committed'])
            final = s.handle(request('finish'))
            self.assertEqual(final['frames'], len(signal))
            self.assertEqual(final['partial'], '')
            self.assertTrue(final['done'])
            self.assertEqual(s.native.resets, 1)
            outcomes.append((s.native.calls, commits))
        self.assertTrue(all(x == outcomes[0] for x in outcomes))
        self.assertEqual(outcomes[0][1], ['A complete prefix and suffix.'])
        self.assertTrue(outcomes[0][0][-1][1])

    def test_finish_remainder(self):
        s = self.session()
        s.handle(audio([0.1]*3))
        r = s.handle(request('finish'))
        self.assertEqual(r['committed'], 'A complete prefix and suffix.')
        self.assertEqual(r['frames'], 3)
        self.assertEqual(len(s.native.calls[0][0]), 3)

    def test_malformed(self):
        s = self.session()
        for value in ('!', '', 'AAAA', base64.b64encode(b'\0'*6404).decode()):
            with self.assertRaises(ValueError):
                s.handle(request('audio', pcm=value))
        for value in (float('nan'), float('inf'), 16.1, -16.1):
            with self.assertRaises(ValueError):
                s.handle(audio([value]))
        for r in ({}, request('unknown'), dict(request('finish'), extra=True)):
            with self.assertRaises(ValueError):
                s.handle(r)
        self.assertEqual(s.frames, 0)

    def test_resampler_overshoot_preserved(self):
        values = [1.1, -1.1, 16.0, -16.0]
        decoded = w.pcm(audio(values)['pcm'])
        for actual, expected in zip(decoded, values):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_long_text_drain_preserves_suffix(self):
        f = Fake()
        original = 'word ' * 1200 + 'suffix'
        f.text = original
        pieces = []
        while len(f.text) >= 2048:
            pieces.append(f.drain())
        pieces.append(f.drain(final=True))
        self.assertEqual(' '.join(pieces), original)
        self.assertEqual(f.resets, 0)

    def test_native_token_decode_partition_equivalence(self):
        package = importlib.util.find_spec('mlx_audio')
        if package is None:
            self.skipTest('Pinned MLX Audio runtime unavailable')
        path = Path(package.origin).parent/'stt/models/nemotron_asr/tokenizer.py'
        native_spec = importlib.util.spec_from_file_location('native_tokenizer', path)
        tokenizer = importlib.util.module_from_spec(native_spec)
        native_spec.loader.exec_module(tokenizer)
        vocabulary = ['<unk>', '<en-US>', '▁Hello', ',', '▁world', '!',
                      '<0xC3>', '<0xA9>', 'é', '▁你好', '<pad>']
        tokens = list(range(len(vocabulary)))
        incremental = ''.join(tokenizer.decode([token], vocabulary) for token in tokens)
        self.assertEqual(incremental, tokenizer.decode(tokens, vocabulary))
        self.assertTrue(incremental.startswith(' Hello'))
        # Native helper is not a byte-fallback decoder; preserve its exact behavior.
        self.assertIn('<0xC3><0xA9>', incremental)

    def test_native_context_is_320ms(self):
        self.assertEqual(w.ATT_CONTEXT, (56, 3))

    def test_voxtral_dispatch(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p/'config.json').write_text('{"model_type":"voxtral_realtime"}')
            (p/'model.safetensors').touch()
            with patch.object(w, 'Voxtral', return_value=object()) as factory:
                self.assertIs(w.Native(w.model_path(folder)), factory.return_value)
                factory.assert_called_once_with(p.resolve())

    def test_voxtral_split_utf8_and_bounded_token_history(self):
        n = object.__new__(w.Voxtral)
        n.text = ''
        n.decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        pieces = {0: b'caf\xc3', 1: b'\xa9 ', 2: b'word '}
        n.model = SimpleNamespace(_tokenizer=SimpleNamespace(token_bytes=pieces.__getitem__))
        n.mx = SimpleNamespace(eval=lambda *a: None, clear_cache=lambda: None)
        mel = SimpleNamespace(_next_k=0, hop_length=160, window_size=400,
                              trim=lambda n: None, _buf=[])
        conv = SimpleNamespace(_state=None)
        s = SimpleNamespace(generated=[], _prev_text='', done=False,
                            _prefilled=False, _adapter_frames=[], _smel=mel,
                            _senc=SimpleNamespace(_caches=[]), _cache=None,
                            _sproj=SimpleNamespace(_buf=None),
                            _sconv=SimpleNamespace(_c0=conv, _c1=conv))
        n.stream = s
        def step(token):
            s.step = lambda **kw: s.generated.append(token)
            n._step()
            self.assertEqual(s.generated, [])
            self.assertEqual(s._prev_text, '')
        step(0)
        self.assertEqual(n.text, 'caf')  # never expose a revisable U+FFFD
        step(1)
        self.assertEqual(n.text, 'café ')
        for _ in range(5000):
            step(2)
            n.drain()
        self.assertLess(len(n.text.encode()), 2048)

    def test_drain_bound_is_utf8_bytes_and_no_silent_cutoff(self):
        f = Fake()
        f.text = '字 ' * 1500
        original = f.text.strip()
        pieces = []
        while len(f.text.encode()) >= 2048:
            pieces.append(f.drain())
        pieces.append(f.drain(final=True))
        self.assertEqual(' '.join(pieces), original)
        f.text = '字' * 3000
        with self.assertRaises(RuntimeError):
            f.drain()

    def test_voxtral_80ms_buffer_and_short_finish(self):
        n = object.__new__(w.Voxtral)
        n.pending_audio = []
        fed, closed = [], []
        n.stream = SimpleNamespace(done=False, feed=fed.append, close=lambda: closed.append(True))
        n._step = lambda: setattr(n.stream, 'done', bool(closed))
        n.push([.1] * 1279)
        self.assertEqual(fed, [])
        n.push([.2])
        self.assertEqual(len(fed[0]), 1280)
        n.push([.3] * 3, final=True)
        self.assertEqual(fed[1], [.3] * 3)
        self.assertTrue(n.stream.done)

    def test_voxtral_endpoint_releases_session_without_cyclic_gc(self):
        class Stream:
            def _adapter_at(self, pos):
                return pos
        n = object.__new__(w.Voxtral)
        n.model = SimpleNamespace(create_streaming_session=lambda **kw: Stream())
        n.mx = SimpleNamespace(clear_cache=lambda: None)
        n.reset()
        old = weakref.ref(n.stream)
        n.stream._vella_base = 10
        n.stream._adapter_frames = []
        self.assertEqual(n.stream._n_adapter(), 10)
        self.assertEqual(n.stream._adapter_at(12), 2)
        n.reset()
        self.assertIsNone(old())  # reference counting, without gc.collect()

    def test_path_and_start(self):
        for value in ('repo/name', '/no-such-model', 42):
            with self.assertRaises((ValueError, OSError)):
                w.model_path(value)
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p/'config.json').write_text('{"model_type":"nemotron_asr"}')
            (p/'model.safetensors').touch()
            s = w.Session(Fake)
            self.assertEqual(s.handle(request('start', model=folder))['frames'], 0)
            with self.assertRaises(ValueError):
                s.handle(request('start', model=folder))

    def test_reject_repository_code_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p/'model.safetensors').touch()
            for filename in ('config.json', 'tokenizer_config.json'):
                for auto_map in ({'AutoModel': 'evil.Model'}, {}, None):
                    (p/'config.json').write_text('{"model_type":"nemotron_asr"}')
                    data = {'auto_map': auto_map}
                    if filename == 'config.json':
                        data['model_type'] = 'nemotron_asr'
                    (p/filename).write_text(json.dumps(data))
                    with self.assertRaises(ValueError):
                        w.model_path(folder)

    def test_subprocess_protocol_and_eof(self):
        for content in (b'', b'{"private":"speech"}\n', b'x'*10001+b'\n'):
            result = subprocess.run([sys.executable, str(ROOT/'Resources/streaming_worker.py')],
                                    input=content, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b'')
            if content:
                r = json.loads(result.stdout)
                self.assertEqual(r['error'], 'Invalid local streaming request.')
                self.assertNotIn('speech', result.stdout.decode())
            else:
                self.assertEqual(result.stdout, b'')

    def test_alarm_clean_exit(self):
        p = subprocess.Popen([sys.executable, str(ROOT/'Resources/streaming_worker.py')],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.15)
            os.kill(p.pid, signal.SIGALRM)
            p.wait(timeout=5)
            output, error = p.communicate(timeout=5)
            self.assertEqual(error, b'')
            self.assertEqual(p.returncode, 0)
            self.assertEqual(json.loads(output)['error'], 'Local streaming transcription failed.')
        finally:
            if p.poll() is None:
                p.kill()
                p.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
