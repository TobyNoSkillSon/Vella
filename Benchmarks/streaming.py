#!/usr/bin/env python3
"""Nemotron shipped-helper measurement; 2.0 has no streaming app API.

No microphone/UI automation. This is not an installed-app API number.
"""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import selectors
import statistics
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from fetch import verify
from run import ROOT, peak, public_status, scoring, shell, write, new_output


class Worker:
    def __init__(self, app, support, recipe, log):
        env = dict(os.environ, VELLA_SUPPORT_DIR=str(support), VELLA_WORKER_DATA_DIR=str(support), VELLA_RECIPE=recipe)
        self.p = subprocess.Popen([str(app / 'Contents/MacOS/VellaStreamingWorker')], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.p.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.status = {}

    def call(self, message):
        rid = str(uuid.uuid4())
        self.p.stdin.write((json.dumps(dict(message, id=rid)) + '\n').encode())
        self.p.stdin.flush()
        deadline = time.monotonic() + 600
        while True:
            while b'\n' not in self.buffer:
                if not self.selector.select(max(0, deadline - time.monotonic())):
                    raise TimeoutError('streaming worker response timed out')
                block = os.read(self.p.stdout.fileno(), 65536)
                if not block:
                    raise RuntimeError('streaming worker exited')
                self.buffer += block
            line, self.buffer = self.buffer.split(b'\n', 1)
            reply = json.loads(line)
            if isinstance(reply.get('status'), dict):
                self.status = reply['status']
            if reply.get('id') == rid:
                if 'error' in reply:
                    raise RuntimeError('streaming worker returned an error; inspect private log')
                return reply
            if time.monotonic() > deadline:
                raise TimeoutError('streaming worker response ID timed out')

    def close(self):
        self.selector.close()
        self.p.stdin.close()
        try:
            self.p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--model-path', type=Path, required=True, help='already installed native or derived Nemotron checkpoint; no downloads')
    p.add_argument('--checkpoint-revision', required=True)
    p.add_argument('--precision', choices=['bf16', 'int8', 'int4'], default='bf16')
    p.add_argument('--path', choices=['Standard', 'Optimized'], default='Optimized')
    p.add_argument('--mode', choices=['Fast', 'Exact'], default='Fast')
    p.add_argument('--suite', choices=['quick', 'full'], default='quick')
    p.add_argument('--repeats', type=int, default=3)
    p.add_argument('--audio-root', type=Path, default=ROOT / '.data')
    p.add_argument('--machine-idle', choices=['yes', 'no', 'unknown'], required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if a.repeats < 3:
        p.error('at least 3 warm passes required')
    forbidden = [k for k in os.environ if k.startswith('VELLA_') and k not in ('VELLA_LOCK_HELD', 'VELLA_MEASURE_WINDOW', 'VELLA_MEASURE_COMPOSITING_GPU')]
    if forbidden:
        p.error('unset inherited experiment switches: ' + ', '.join(sorted(forbidden)))
    out = a.out.expanduser().resolve()
    if out.exists():
        p.error('output already exists; use a fresh --out for each model/cell/run')
    app = a.app.expanduser().resolve()
    model_path = a.model_path.expanduser().resolve()
    if not model_path.is_dir():
        p.error('checkpoint is not installed')
    manifest_path = ROOT / 'suites' / ('v2-quick' if a.suite == 'quick' else 'v2') / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    audio = a.audio_root.expanduser().resolve()
    # Match the original f32 transport; silence and packet layout are pinned in the receipt.
    pcm = [(c, np.concatenate((verify(c, audio).astype(np.float32) / np.float32(32768), np.zeros(19200, np.float32)))) for c in manifest['clips']]
    if a.dry_run:
        print(f"dry run: {manifest['id']}, {len(pcm)} clips, stream-concat-gap19200, 1600-sample packets; no worker started")
        return
    new_output(out)
    support = out / 'support'; support.mkdir()
    recipe = 'standard' if a.path == 'Standard' else 'optimized_' + a.mode.lower()
    passes = []
    model_id = 'nemotron-3.5-streaming-0.6b'
    with (out / 'worker.log').open('wb') as log:
        w = Worker(app, support, recipe, log)
        try:
            def feed(data):
                pieces = []
                for i in range(0, len(data), 1600):
                    reply = w.call({'op': 'audio', 'pcm': base64.b64encode(data[i:i + 1600].astype('<f4').tobytes()).decode()})
                    if reply.get('committed'):
                        pieces.append(reply['committed'])
                return ' '.join(pieces)
            w.call({'op': 'start', 'model': str(model_path)})
            feed(np.concatenate((pcm[0][1][:32000], np.zeros(19200, np.float32))))
            w.call({'op': 'finish'})  # end warmup; keep the loaded model, discard its stream state/text
            warm_status = public_status(w.status)
            for i in range(a.repeats):
                w.call({'op': 'start', 'model': str(model_path)})
                t = time.monotonic()
                rows = [{'id': c['id'], 'transcript': feed(data)} for c, data in pcm]
                tail = w.call({'op': 'finish'}).get('committed')
                if tail:
                    rows[-1]['transcript'] = (rows[-1]['transcript'] + ' ' + tail).strip()
                elapsed = time.monotonic() - t
                if public_status(w.status) != warm_status:
                    raise RuntimeError('actual streaming engine/components changed during pass')
                raw = {'modelID': model_id, 'suiteID': manifest['id'], 'precision': a.precision, 'transport': 'shipped-streaming-helper',
                       'sessionLayout': 'stream-concat-gap19200;1600-sample-packets;one-session-per-pass', 'clips': rows}
                write(out / f'pass-{i + 1}.json', raw)
                score = scoring.score(manifest, raw, json.loads((ROOT / 'scorer/support.json').read_text()), 0)
                write(out / f'score-{i + 1}.json', score)
                passes.append({'wer_percent': score['words']['rate'] * 100, 'wall_seconds': elapsed,
                    'speed_x_realtime': sum(c['samples'] for c in manifest['clips']) / 16000 / elapsed})
            actual = public_status(w.status)
            if actual.get('recipe') != recipe or 'optimizations' not in actual:
                raise RuntimeError('helper did not report the requested recipe and active components')
            gpu = json.loads(shell('system_profiler', 'SPDisplaysDataType', '-json'))['SPDisplaysDataType'][0]
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            result = {'schema_version':1,'recorded_at':datetime.now(timezone.utc).isoformat(),
                'hardware':{'chip':shell('sysctl','-n','machdep.cpu.brand_string'),'gpu_cores':int(gpu['sppci_cores']),
                    'ram_bytes':int(shell('sysctl','-n','hw.memsize')),'macos_version':shell('sw_vers','-productVersion'),
                    'macos_build':shell('sw_vers','-buildVersion'),'power_source':'AC' if 'AC Power' in shell('pmset','-g','batt') else 'battery'},
                'vella':{'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
                    'worker_sha256':hashlib.sha256((app/'Contents/MacOS/VellaStreamingWorker').read_bytes()).hexdigest()},
                'model':{'id':model_id,'precision':a.precision,'path':a.path,'mode':a.mode,'checkpoint_revision':a.checkpoint_revision,
                    'status':actual,'status_line':'direct shipped-helper status; vella status does not observe this separate worker'},
                'suite':{'kind':a.suite,'id':manifest['id'],'version':manifest['version'],'manifest_sha256':hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                    'quality_label':'estimate' if a.suite=='quick' else 'full'},
                'protocol':{'transport':'shipped-streaming-helper','repeats':a.repeats,'warm_state':'2-second audio + 1.2-second gap warmup; fresh stream before each timed pass; loaded worker reused',
                    'machine_idle':a.machine_idle,'request_errors':0,'worker_exits':0,'speed':'audio seconds / serial helper warm wall seconds; excludes decode; includes 1.2s gap per clip',
                    'peak_ram':'worker lifetime peak physical footprint; decimal MB','session_layout':'stream-concat-gap19200;1600-sample-packets;one-session-per-pass'},
                'metrics':{'wer_percent':statistics.median(x['wer_percent'] for x in passes),'speed_x_realtime':statistics.median(x['speed_x_realtime'] for x in passes),
                    'peak_ram_mb':peak(w.p.pid)},'passes':passes,'scorer':{'normalizer':scoring.NORMALIZER_VERSION,'sha256':scoring.SCORER_SHA256},'personal_recordings_included':False}
            write(out/'result.json',result)
            print('result: '+str(out/'result.json'))
        finally:
            w.close()


if __name__ == '__main__':
    main()
