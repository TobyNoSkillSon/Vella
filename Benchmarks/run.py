#!/usr/bin/env python3
"""Serial installed-app API benchmark, with an isolated profile and no downloads."""
import argparse
import ctypes
import hashlib
import json
import os
import plistlib
import signal
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scorer/Benchmarks/v2'))
import scoring
from fetch import verify


def shell(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def peak(pid):
    # rusage_info_v4, ri_lifetime_max_phys_footprint: unified-memory footprint, not RSS.
    data = (ctypes.c_uint64 * 64)()
    if ctypes.CDLL(None).proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(data)) != 0:
        raise RuntimeError('cannot measure worker peak physical footprint')
    return data[30] / 1e6


def public_status(model):
    # Whitelist: never submit paths, tokens, timestamps, user settings or recording history.
    result = {k: model[k] for k in ('engine', 'precision', 'mode', 'selection', 'requested_selection', 'optimizations', 'fallback', 'fallbacks', 'fallback_reason', 'worker_version', 'recipe', 'engine_reason', 'version') if k in model}
    result['fallbacks'] = model.get('fallbacks', [])
    requested_optimized = model.get('recipe', '').startswith('optimized') or (model.get('requested_selection') or {}).get('path') == 'optimized'
    if requested_optimized and model.get('engine_reason') and model.get('engine') != 'optimized':
        result['fallbacks'] = result['fallbacks'] + [model['engine_reason']]
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--suite', choices=['quick', 'full'], default='quick')
    p.add_argument('--audio-root', type=Path, default=ROOT / '.data')
    p.add_argument('--models-from', type=Path, default=Path.home() / 'Library/Application Support/Vella')
    p.add_argument('--model', default='parakeet-v3-ultra')
    p.add_argument('--precision', choices=['bf16', 'fp16', 'int8', 'int4'], default='bf16')
    p.add_argument('--path', choices=['Standard', 'Optimized'], default='Optimized')
    p.add_argument('--mode', choices=['Exact', 'Fast'], default='Fast')
    p.add_argument('--repeats', type=int, default=3)
    p.add_argument('--machine-idle', choices=['yes', 'no', 'unknown'], required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--dry-run', action='store_true', help='verify suite, audio and installed checkpoint; never launch the app')
    a = p.parse_args()
    if a.repeats < 3:
        p.error('at least three warm passes required')
    app = a.app.expanduser().resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    catalog = json.loads((app / 'Contents/Resources/models.json').read_text())
    family = next((f for f in catalog['families'] if f['id'] == a.model), None)
    if family is None:
        p.error('model ID is not in the installed app catalog')
    if family['mode'] != 'dictation':
        p.error('2.0.0 has no streaming API; use streaming.py, labelled shipped-helper, for Nemotron')
    suite = ROOT / 'suites' / ('v2-quick' if a.suite == 'quick' else 'v2') / 'manifest.json'
    manifest = json.loads(suite.read_text())
    audio = a.audio_root.expanduser().resolve()
    for clip in manifest['clips']:
        verify(clip, audio)
    registry_path = a.models_from.expanduser() / 'models-installed.json'
    registry = json.loads(registry_path.read_text())
    native = next(v for v in family['variants'].values() if not v.get('derivedFrom'))
    if native['id'] not in registry or not Path(registry[native['id']]['path']).is_dir():
        sys.exit('native checkpoint is not installed; ask user before Get')
    if a.dry_run:
        print(json.dumps({'suite': manifest['id'], 'clips': len(manifest['clips']),
            'audio_minutes': sum(c['samples'] for c in manifest['clips']) / 16000 / 60,
            'manifest_sha256': hashlib.sha256(suite.read_bytes()).hexdigest(),
            'app_version': info['CFBundleShortVersionString'], 'model': a.model,
            'precision': a.precision, 'path': a.path, 'mode': a.mode, 'repeats': a.repeats,
            'action': 'dry run: no launch, load or inference'}))
        return
    out = a.out.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=False)
    support = out / 'support'
    support.mkdir()
    write(support / 'models-installed.json', {native['id']: registry[native['id']]})
    (support / 'home').mkdir()
    env = dict(os.environ, HOME=str(support / 'home'), VELLA_SUPPORT_DIR=str(support), VELLA_NO_LAUNCH='1',
               VELLA_REGISTER_APP='0', VELLA_QA_HEADLESS='1', VELLA_UPDATE='0')
    # Refuse inherited experiment switches: shipped defaults are the baseline.
    forbidden = sorted(k for k in os.environ if k.startswith('VELLA_') and k not in ('VELLA_LOCK_HELD', 'VELLA_MEASURE_WINDOW', 'VELLA_MEASURE_COMPOSITING_GPU'))
    if forbidden:
        sys.exit('unset inherited Vella experiment switches: ' + ', '.join(forbidden))
    cli = app / 'Contents/Helpers/vella'
    started = time.monotonic()
    with (out / 'app.log').open('wb') as log:
        proc = subprocess.Popen([str(app / 'Contents/MacOS/Vella')], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        try:
            def command(*args):
                return subprocess.check_output([str(cli), *args], env=env, text=True, stderr=subprocess.PIPE, timeout=600).strip()

            deadline = time.monotonic() + 60
            while not (support / 'worker-status.json').exists():
                if proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('isolated app did not become ready; inspect app.log')
                time.sleep(.5)
            command('select', a.model, '--precision', a.precision, '--path', a.path, '--mode', a.mode)
            command('load', a.model)

            def status():
                state = json.loads((support / 'worker-status.json').read_text())
                port = state['api_port']
                request = urllib.request.Request(f'http://127.0.0.1:{port}/status', headers={'X-Vella-Token': state['api_token']})
                with urllib.request.urlopen(request, timeout=10) as r:
                    return json.load(r), state

            status_line = command('status')
            before, state = status()
            model = before['models'][a.model]
            expected = public_status(model)
            pid = model['pid']

            def transcribe(clip):
                body = json.dumps({'path': str(audio / clip['file']), 'model': a.model, 'response_format': 'json'}).encode()
                req = urllib.request.Request(f'http://127.0.0.1:{state["api_port"]}/v1/audio/transcriptions', data=body,
                    headers={'Content-Type': 'application/json', 'X-Vella-Token': state['api_token']})
                t = time.monotonic()
                with urllib.request.urlopen(req, timeout=1800) as r:
                    text = json.load(r)['text'].strip()
                return {'id': clip['id'], 'transcript': text, 'wall_s': time.monotonic() - t}

            transcribe(manifest['clips'][0])  # one whole clip; excluded from warm speed
            passes = []
            for i in range(a.repeats):
                t = time.monotonic()
                predictions = [transcribe(c) for c in manifest['clips']]
                elapsed = time.monotonic() - t
                after, _ = status()
                if public_status(after['models'][a.model]) != expected or after['models'][a.model]['pid'] != pid:
                    raise RuntimeError('engine/selection/worker changed during the run; do not publish timings')
                raw = {'modelID': a.model, 'suiteID': manifest['id'], 'precision': a.precision, 'transport': 'installed-app-api', 'clips': predictions}
                write(out / f'pass-{i + 1}.json', raw)
                score = scoring.score(manifest, raw, json.loads((ROOT / 'scorer/support.json').read_text()), 0)
                write(out / f'score-{i + 1}.json', score)
                passes.append({'wer_percent': (score['words']['rate'] * 100), 'wall_seconds': elapsed,
                               'speed_x_realtime': sum(c['samples'] / 16000 for c in manifest['clips']) / elapsed})
                print(f"pass {i + 1}: WER {(score['words']['rate'] * 100):.4f}%, {passes[-1]['speed_x_realtime']:.2f}x", flush=True)
            peak_mb = peak(pid)
            # Save only shareable hardware/status fields; full support/logs stay ignored and private.
            gpu = json.loads(shell('system_profiler', 'SPDisplaysDataType', '-json'))['SPDisplaysDataType'][0]
            result = {'schema_version': 1, 'recorded_at': datetime.now(timezone.utc).isoformat(),
                'hardware': {'chip': shell('sysctl', '-n', 'machdep.cpu.brand_string'), 'gpu_cores': int(gpu['sppci_cores']),
                    'ram_bytes': int(shell('sysctl', '-n', 'hw.memsize')), 'macos_version': shell('sw_vers', '-productVersion'),
                    'macos_build': shell('sw_vers', '-buildVersion'), 'power_source': 'AC' if 'AC Power' in shell('pmset', '-g', 'batt') else 'battery'},
                'vella': {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                    'app_sha256': hashlib.sha256((app / 'Contents/MacOS/Vella').read_bytes()).hexdigest(),
                    'worker_sha256': hashlib.sha256((app / 'Contents/MacOS/VellaWorker').read_bytes()).hexdigest()},
                'model': {'id': a.model, 'precision': a.precision, 'path': a.path, 'mode': a.mode,
                    'checkpoint_revision': registry[native['id']].get('revision'), 'status': expected, 'status_line': status_line},
                'suite': {'kind': a.suite, 'id': manifest['id'], 'version': manifest['version'],
                    'manifest_sha256': hashlib.sha256(suite.read_bytes()).hexdigest(), 'quality_label': 'estimate' if a.suite == 'quick' else 'full'},
                'protocol': {'transport': 'installed-app-api', 'repeats': a.repeats, 'warm_state': 'one whole-clip warmup; model remains loaded',
                    'machine_idle': a.machine_idle, 'isolation': 'fresh support/home; headless API; updates disabled; native checkpoint read in place', 'request_errors': 0, 'worker_exits': 0, 'speed': 'audio seconds / serial API wall seconds; includes decode and app segmentation',
                    'peak_ram': 'worker lifetime peak physical footprint; decimal MB; includes load and warmup'},
                'metrics': {'wer_percent': statistics.median(x['wer_percent'] for x in passes),
                    'speed_x_realtime': statistics.median(x['speed_x_realtime'] for x in passes), 'peak_ram_mb': peak_mb}, 'passes': passes,
                'scorer': {'normalizer': scoring.NORMALIZER_VERSION, 'sha256': scoring.SCORER_SHA256},
                'personal_recordings_included': False}
            write(out / 'result.json', result)
            print(f"result: {out / 'result.json'}; total {time.monotonic() - started:.1f}s", flush=True)
        finally:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


if __name__ == '__main__':
    main()
