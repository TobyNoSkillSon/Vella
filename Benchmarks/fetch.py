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
    todo = []
    for clip in manifest['clips']:
        if (a.audio_root / clip['file']).exists():
            verify(clip, a.audio_root)
        else:
            todo.append(clip)
    if todo and a.verify_only:
        sys.exit(f"{len(todo)} clips missing; run fetch.py after download consent")
    if todo and not a.yes:
        sys.exit(f"{len(todo)} clips need upstream audio. Ask the user first; rerun with --yes. Full source cache can exceed 6 GB.")
    for allocation in sorted({c['allocation'] for c in todo}):
        mod = importlib.import_module('sources.' + modules[allocation])
        ctx = C.Context(a.cache, allocation)
        pairs = []
        for clip in todo:
            if clip['allocation'] != allocation:
                continue
            candidate = C.Candidate(**{k: clip[k] for k in ('key', 'language', 'duration', 'reference', 'referenceType', 'group', 'speaker', 'conditions', 'stratum', 'origin', 'extra')}, lexicalReference=clip.get('lexicalReference'))
            pairs.append((clip, candidate))
        if hasattr(mod, 'prepare'):
            mod.prepare(ctx, [c for _, c in pairs])
        for clip, candidate in pairs:
            samples, rate, channel = mod.extract(ctx, candidate)
            pcm = C.finalize(C.to_mono(samples, channel), rate)
            if len(pcm) != clip['samples'] or C.pcm_sha(pcm) != clip['pcmSha256']:
                sys.exit(f"upstream PCM mismatch: {clip['id']}; do not change the manifest or publish a partial result")
            C.write_flac(a.audio_root / clip['file'], pcm)
            verify(clip, a.audio_root)
        print(f"{allocation}: {len(pairs)} clips verified", flush=True)
    print(f"{manifest['id']}: {len(manifest['clips'])} clips verified")


if __name__ == '__main__':
    main()
