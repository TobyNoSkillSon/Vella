#!/usr/bin/env python3
"""Small local self-check for one contribution. Maintainers review by hand."""
import argparse
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def check(r):
    assert r['schema_version'] == 1
    for k in ('chip', 'gpu_cores', 'ram_bytes', 'macos_version', 'macos_build', 'power_source'):
        assert r['hardware'][k] not in ('', None), 'missing hardware ' + k
    assert isinstance(r['hardware']['gpu_cores'], int) and r['hardware']['gpu_cores'] > 0
    assert isinstance(r['hardware']['ram_bytes'], int) and r['hardware']['ram_bytes'] > 0
    assert r['hardware']['power_source'] in ('AC', 'battery')
    for k in ('version', 'build'):
        assert str(r['vella'][k]), 'missing Vella ' + k
    for k in ('id', 'precision', 'path', 'mode', 'checkpoint_revision', 'status', 'status_line'):
        assert r['model'][k], 'missing model ' + k
    assert r['model']['precision'] in ('bf16', 'fp16', 'int8', 'int4')
    assert r['model']['path'] in ('Standard', 'Optimized')
    assert r['model']['mode'] in ('Exact', 'Fast')
    status = r['model']['status']
    assert status['engine'] in ('mlx', 'optimized', 'stock', 'standard'), 'unknown actual engine'
    assert ('selection' in status or 'recipe' in status) and 'optimizations' in status, 'missing actual path/components'
    assert 'fallbacks' in status, 'record actual fallback state (an empty list means none)'
    kind = r['suite']['kind']
    assert kind in ('quick', 'full')
    suite = ROOT / 'suites' / ('v2-quick' if kind == 'quick' else 'v2') / 'manifest.json'
    m = json.loads(suite.read_text())
    assert r['suite']['id'] == m['id'] and r['suite']['version'] == m['version']
    assert r['suite']['manifest_sha256'] == hashlib.sha256(suite.read_bytes()).hexdigest()
    assert r['suite']['quality_label'] == ('estimate' if kind == 'quick' else 'full')
    assert r['protocol']['transport'] in ('installed-app-api', 'shipped-streaming-helper')
    assert r['protocol']['repeats'] >= 3 and len(r['passes']) == r['protocol']['repeats']
    assert r['protocol']['warm_state']
    assert r['protocol']['machine_idle'] in ('yes', 'no', 'unknown')
    assert r['protocol']['speed'] and r['protocol']['peak_ram']
    for k in ('wer_percent', 'speed_x_realtime', 'peak_ram_mb'):
        v = r['metrics'][k]
        assert isinstance(v, (int, float)) and math.isfinite(v) and v >= 0, 'invalid metric ' + k
    assert r['metrics']['speed_x_realtime'] > 0 and r['metrics']['peak_ram_mb'] > 0
    for row in r['passes']:
        assert all(isinstance(row[k], (int, float)) and math.isfinite(row[k]) for k in ('wall_seconds', 'speed_x_realtime', 'wer_percent'))
        assert row['wall_seconds'] > 0 and row['speed_x_realtime'] > 0 and row['wer_percent'] >= 0
        expected_speed = sum(c['samples'] for c in m['clips']) / 16000 / row['wall_seconds']
        assert math.isclose(row['speed_x_realtime'], expected_speed, rel_tol=1e-6), 'speed arithmetic mismatch'
    for k in ('wer_percent', 'speed_x_realtime'):
        assert math.isclose(r['metrics'][k], statistics.median(x[k] for x in r['passes']), abs_tol=1e-6), 'median mismatch'
    assert r['scorer']['normalizer'] == 'vella-v2-lexical-1.0.0'
    assert r['scorer']['sha256'] == hashlib.sha256((ROOT / 'scorer/Benchmarks/v2/scoring.py').read_bytes()).hexdigest()
    if 'energy_j_per_audio_minute' in r['metrics']:
        assert math.isfinite(r['metrics']['energy_j_per_audio_minute']) and r['metrics']['energy_j_per_audio_minute'] > 0, 'absent energy must be omitted, never zero'
        e = r['protocol']['energy']
        assert e['method'] == 'powermetrics-cpu-gpu-idle-subtracted-v1' and e['admin_consent'] is True
        assert e['interval_ms'] == 100 and e['idle_before_seconds'] >= 10 and e['idle_after_seconds'] >= 10
        assert re.fullmatch('[0-9a-f]{64}', e['raw_sha256'])
        assert e['idle_watts'] >= 0 and e['warm_start_utc'] and e['warm_end_utc'] and e['notes']
    assert r['personal_recordings_included'] is False, 'personal recordings cannot be included'
    text = json.dumps(r)
    assert not re.search(r'/(?:Users|home)/|api_token|Bearer ', text), 'private path or credential in result'
    return 'example only; do not submit' if r.get('example') else 'estimate' if kind == 'quick' else 'full'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('result', type=Path)
    a = p.parse_args()
    try:
        label = check(json.loads(a.result.read_text()))
    except (AssertionError, KeyError, ValueError, TypeError) as error:
        p.exit(1, f'result rejected: {error}\n')
    print('result self-check: ' + label)


if __name__ == '__main__':
    main()
