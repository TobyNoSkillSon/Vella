#!/usr/bin/env python3
"""Reconstruct frozen clips; never reselect or rewrite a suite manifest."""
import argparse
import importlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'fetchers'))
import common as C


def verify(clip, root):
    import soundfile as sf
    pcm, rate = sf.read(root / clip['file'], dtype='int16')
    if rate != 16000 or pcm.ndim != 1 or len(pcm) != clip['samples'] or C.pcm_sha(pcm) != clip['pcmSha256']:
        raise ValueError(f"PCM identity mismatch: {clip['id']}")
    return pcm


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite', choices=['quick', 'full'], default='quick')
    p.add_argument('--audio-root', type=Path, default=ROOT / '.data')
    p.add_argument('--cache', type=Path, default=ROOT / '.cache')
    p.add_argument('--verify-only', action='store_true')
    p.add_argument('--yes', action='store_true', help='user consent for upstream audio downloads obtained')
    a = p.parse_args()
    manifest = json.loads((ROOT / 'suites' / ('v2-quick' if a.suite == 'quick' else 'v2') / 'manifest.json').read_text())
    plan = json.loads((ROOT / 'suites/v2/suite.json').read_text())
    modules = {x['id']: x['source'] for x in plan['allocations']}
    results = {allocation: {'verified': 0, 'failed': 0} for allocation in sorted({c['allocation'] for c in manifest['clips']})}

    def failed(clip, error):
        results[clip['allocation']]['failed'] += 1
        print(f"{clip['allocation']}: FAIL {clip['id']}: {error}", flush=True)

    todo = []
    for clip in manifest['clips']:
        if (a.audio_root / clip['file']).exists():
            try:
                verify(clip, a.audio_root)
                results[clip['allocation']]['verified'] += 1
            except Exception as error:
                failed(clip, error)
        else:
            todo.append(clip)
    if todo and a.verify_only:
        for clip in todo:
            failed(clip, 'clip missing; run fetch.py after download consent')
        todo = []
    if todo and not a.yes:
        for clip in todo:
            failed(clip, 'upstream audio needed. Ask the user first; rerun with --yes. Full source cache can exceed 6 GB.')
        todo = []
    for allocation in sorted({c['allocation'] for c in todo}):
        clips = [c for c in todo if c['allocation'] == allocation]
        try:
            mod = importlib.import_module('sources.' + modules[allocation])
            ctx = C.Context(a.cache, allocation)
            pairs = []
            for clip in clips:
                candidate = C.Candidate(**{k: clip[k] for k in ('key', 'language', 'duration', 'reference', 'referenceType', 'group', 'speaker', 'conditions', 'stratum', 'origin', 'extra')}, lexicalReference=clip.get('lexicalReference'))
                pairs.append((clip, candidate))
            if hasattr(mod, 'prepare'):
                mod.prepare(ctx, [c for _, c in pairs])
        except Exception as error:
            for clip in clips:
                failed(clip, error)
            continue
        for clip, candidate in pairs:
            try:
                samples, rate, channel = mod.extract(ctx, candidate)
                pcm = C.finalize(C.to_mono(samples, channel), rate)
                if len(pcm) != clip['samples'] or C.pcm_sha(pcm) != clip['pcmSha256']:
                    raise ValueError(f"upstream PCM mismatch: {clip['id']}; do not change the manifest or publish a partial result")
                C.write_flac(a.audio_root / clip['file'], pcm)
                verify(clip, a.audio_root)
                results[allocation]['verified'] += 1
            except Exception as error:
                failed(clip, error)
    print('Per-source summary:', flush=True)
    for allocation, result in results.items():
        print(f"{allocation} ({modules[allocation]}): {result['verified']} verified, {result['failed']} failed", flush=True)
    failures = sum(r['failed'] for r in results.values())
    if failures:
        print(f"{manifest['id']}: INCOMPLETE; {failures} clips failed; do not publish a partial result", flush=True)
        return 1
    print(f"{manifest['id']}: {len(manifest['clips'])} clips verified")
    return 0


if __name__ == '__main__':
    sys.exit(main())
