"""Exercise the streaming runner's session boundaries without GPU inference."""
import contextlib
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import streaming


class FakeWorker:
    def __init__(self):
        self.p = SimpleNamespace(pid=42)
        self.status = {'engine': 'optimized', 'recipe': 'optimized_fast', 'optimizations': {'keep_cache': True},
                       'engine_reason': 'Self-tested on this Mac against stock MLX (identical streamed text).'}
        self.active = False
        self.starts = self.finishes = 0
        self.closed = False

    def call(self, message):
        if message['op'] == 'start':
            if self.active:
                raise RuntimeError('previous session was not finished')
            self.active = True
            self.counter = 0
            self.starts += 1
        elif message['op'] == 'audio':
            assert self.active
            self.counter += 1
            return {'committed': f'word{self.counter}'}
        elif message['op'] == 'finish':
            assert self.active
            self.active = False
            self.finishes += 1
        return {}

    def close(self):
        self.closed = True


class StreamingTest(unittest.TestCase):
    def test_every_timed_pass_starts_fresh_after_separate_warmup(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'suites/v2-quick').mkdir(parents=True)
            manifest = {'id': 'vella-v2-quick', 'version': 'fixture',
                        'clips': [{'id': 'one', 'file': 'one.flac', 'samples': 320}]}
            (root / 'suites/v2-quick/manifest.json').write_text(json.dumps(manifest))
            (root / 'scorer').mkdir()
            (root / 'scorer/support.json').write_text('{}')
            app = root / 'Vella.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/VellaStreamingWorker').write_bytes(b'fixture')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
                {'CFBundleShortVersionString': '2.0.1', 'CFBundleVersion': '36'}))
            model = root / 'model'
            model.mkdir()
            out = root / 'out'
            worker = FakeWorker()

            def shell(*args):
                if args[0] == 'system_profiler':
                    return json.dumps({'SPDisplaysDataType': [{'sppci_cores': '40'}]})
                if args[-1] == 'hw.memsize':
                    return str(128 * 1024**3)
                if args[0] == 'pmset':
                    return 'AC Power'
                return 'fixture'

            argv = ['streaming.py', '--app', str(app), '--model-path', str(model),
                    '--checkpoint-revision', 'pinned', '--machine-idle', 'no', '--out', str(out)]
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, {}, clear=True), \
                 patch.object(streaming, 'ROOT', root), patch.object(streaming, 'Worker', return_value=worker), \
                 patch.object(streaming, 'verify', return_value=np.zeros(320, np.int16)), \
                 patch.object(streaming, 'shell', side_effect=shell), patch.object(streaming, 'peak', return_value=123), \
                 patch.object(streaming.scoring, 'score', return_value={'words': {'rate': .01}}), \
                 contextlib.redirect_stdout(io.StringIO()):
                streaming.main()

            transcripts = [json.loads((out / f'pass-{i}.json').read_text())['clips'] for i in (1, 2, 3)]
            self.assertEqual(transcripts[0], transcripts[1])
            self.assertEqual(transcripts[1], transcripts[2])
            self.assertTrue(transcripts[0][0]['transcript'].startswith('word1 '))
            self.assertEqual((worker.starts, worker.finishes), (4, 4))
            self.assertTrue(worker.closed)
            self.assertFalse(worker.active)
            result = json.loads((out / 'result.json').read_text())
            self.assertEqual(result['model']['status']['fallbacks'], [])
            self.assertIn('fresh stream', result['protocol']['warm_state'])


if __name__ == '__main__':
    unittest.main()
