#!/usr/bin/env python3
"""Vella benchmark v2 builder.

  build.py plan                          show allocations and targets
  build.py build <allocation>... [--cache DIR]   select + extract clips, write parts/<allocation>.json
  build.py merge                         merge parts into manifest.json
  build.py fetch [--cache DIR]           rebuild audio for every manifest clip from pinned sources (no reselection)
  build.py verify                        check audio PCM hashes and durations against manifest.json

Run with the tooling environment in tools/requirements.txt, never Vella's runtime Python.
"""
from __future__ import annotations

import argparse, dataclasses, importlib, json, pathlib, sys, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import common as C  # noqa: E402

SUITE = C.SUITE
PARTS = SUITE / 'parts'
AUDIO = SUITE / 'audio'
PLAN = json.loads((SUITE / 'suite.json').read_text())


def allocation(aid):
    for a in PLAN['allocations']:
        if a['id'] == aid:
            return a
    raise SystemExit(f'unknown allocation {aid}')


def adapter(name):
    return importlib.import_module(f'sources.{name}')


def clip_record(a, mod, cand: C.Candidate, pcm, path):
    rec = dict(
        id=f"{a['id']}-{C.safe_id(cand.key)}", allocation=a['id'], source=mod.SOURCE['id'],
        file=str(path.relative_to(SUITE)), sha256=C.sha_file(path), pcmSha256=C.pcm_sha(pcm),
        samples=int(len(pcm)), duration=round(len(pcm) / C.RATE, 4), language=cand.language,
        tracks=a['tracks'], scoring=a.get('scoring', 'wer'),
        reference=C.clean_text(cand.reference), referenceType=cand.referenceType,
        group=cand.group, speaker=cand.speaker, conditions=list(cand.conditions), stratum=cand.stratum,
        origin=cand.origin, extra=cand.extra, key=cand.key,
    )
    if cand.lexicalReference is not None:
        rec['lexicalReference'] = C.clean_text(cand.lexicalReference)
    return rec


def extract_pcm(ctx, mod, cand):
    samples, rate, channel = mod.extract(ctx, cand)
    return C.finalize(C.to_mono(samples, channel), rate)


def build(aid, cache):
    a = allocation(aid); mod = adapter(a['source'])
    ctx = C.Context(cache, aid)
    params = a.get('params', {})
    t0 = time.time()
    cands = mod.candidates(ctx, **params)
    keys = [c.key for c in cands]
    if len(keys) != len(set(keys)):
        raise SystemExit(f'{aid}: duplicate candidate keys')
    select = getattr(mod, 'select', None)
    target = a['minutes'] * 60
    chosen = select(ctx, cands, target, **params) if select else C.stratified_select(cands, target, seed=PLAN['seed'])
    if hasattr(mod, 'prepare'):
        mod.prepare(ctx, chosen)  # optional one-pass bulk fetch of the selected items
    clips = []
    for cand in chosen:
        pcm = extract_pcm(ctx, mod, cand)
        path = AUDIO / aid / f"{C.safe_id(cand.key)}.flac"
        C.write_flac(path, pcm)
        clips.append(clip_record(a, mod, cand, pcm, path))
    part = dict(allocation=a, source=mod.SOURCE, candidateCount=len(cands),
                selectedSeconds=round(sum(c['duration'] for c in clips), 3), clips=clips,
                builtAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    PARTS.mkdir(exist_ok=True)
    (PARTS / f'{aid}.json').write_text(json.dumps(part, indent=1, ensure_ascii=False) + '\n')
    print(f"{aid}: {len(clips)} clips, {part['selectedSeconds']/60:.2f} min of {a['minutes']} target, "
          f"{len(cands)} candidates, {time.time()-t0:.0f}s")


def merge():
    clips, sources, missing = [], {}, []
    for a in PLAN['allocations']:
        p = PARTS / f"{a['id']}.json"
        if not p.exists():
            missing.append(a['id']); continue
        part = json.loads(p.read_text())
        if part['allocation'] != a:
            raise SystemExit(f"{a['id']}: part was built from a different allocation; rebuild it")
        sources[part['source']['id']] = part['source']
        clips.extend(part['clips'])
    ids = [c['id'] for c in clips]
    assert len(ids) == len(set(ids)), 'duplicate clip ids'
    def minutes(pred):
        return round(sum(c['duration'] for c in clips if pred(c)) / 60, 2)
    langs = sorted({c['language'] for c in clips})
    manifest = dict(
        id=PLAN['id'], version=PLAN['version'], description=PLAN['description'], seed=PLAN['seed'],
        sampleRate=C.RATE, audioSeconds=round(sum(c['duration'] for c in clips), 3),
        summary=dict(
            englishMinutes=minutes(lambda c: c['language'] == 'en'),
            nonEnglishMinutes=minutes(lambda c: c['language'] != 'en'),
            formattingMinutes=minutes(lambda c: 'formatting' in c['tracks']),
            perLanguageMinutes={l: minutes(lambda c, l=l: c['language'] == l) for l in langs},
            perAllocationMinutes={a['id']: minutes(lambda c, i=a['id']: c['allocation'] == i) for a in PLAN['allocations']},
        ),
        tracks=PLAN['tracks'], sources=sources, incomplete=missing, clips=clips,
    )
    (SUITE / 'manifest.json').write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
    print(json.dumps(manifest['summary'], indent=1), '\nmissing:', missing)


def load_manifest():
    return json.loads((SUITE / 'manifest.json').read_text())


def _candidate(rec):
    return C.Candidate(key=rec['key'], language=rec['language'], duration=rec['duration'], reference=rec['reference'],
                       referenceType=rec['referenceType'], group=rec['group'], speaker=rec['speaker'],
                       conditions=tuple(rec['conditions']), stratum=rec['stratum'],
                       lexicalReference=rec.get('lexicalReference'), origin=rec['origin'], extra=rec['extra'])


def fetch(cache, only=None):
    m = load_manifest(); bad = 0
    todo = [r for r in m['clips'] if (not only or r['allocation'] in only)
            and not ((SUITE / r['file']).exists() and C.sha_file(SUITE / r['file']) == r['sha256'])]
    for aid in sorted({r['allocation'] for r in todo}):
        mod = adapter(allocation(aid)['source'])
        if hasattr(mod, 'prepare'):
            mod.prepare(C.Context(cache, aid), [_candidate(r) for r in todo if r['allocation'] == aid])
    for rec in todo:
        if only and rec['allocation'] not in only:
            continue
        a = allocation(rec['allocation']); mod = adapter(a['source'])
        path = SUITE / rec['file']
        cand = _candidate(rec)
        pcm = extract_pcm(C.Context(cache, rec['allocation']), mod, cand)
        if C.pcm_sha(pcm) != rec['pcmSha256']:
            print('PCM MISMATCH', rec['id']); bad += 1; continue
        C.write_flac(path, pcm)
    print('fetch done' if not bad else f'{bad} clips failed PCM verification'); return bad


def verify():
    import soundfile as sf
    m = load_manifest(); problems = []
    for rec in m['clips']:
        path = SUITE / rec['file']
        if not path.exists():
            problems.append((rec['id'], 'missing')); continue
        pcm, rate = sf.read(str(path), dtype='int16')
        if rate != C.RATE or pcm.ndim != 1:
            problems.append((rec['id'], 'format'))
        elif C.pcm_sha(pcm) != rec['pcmSha256']:
            problems.append((rec['id'], 'pcm hash'))
        elif abs(len(pcm) / C.RATE - rec['duration']) > 1e-3:
            problems.append((rec['id'], 'duration'))
        if not rec['reference'].strip():
            problems.append((rec['id'], 'empty reference'))
    print(f"{len(m['clips'])} clips, {len(problems)} problems"); [print(*p) for p in problems[:50]]
    return len(problems)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['plan', 'build', 'merge', 'fetch', 'verify'])
    p.add_argument('allocations', nargs='*')
    p.add_argument('--cache', default=str(SUITE / '.cache'))
    args = p.parse_args()
    if args.command == 'plan':
        tot = 0
        for a in PLAN['allocations']:
            tot += a['minutes']; print(f"{a['id']:28} {a['source']:18} {a['minutes']:6.1f} min  {','.join(a['tracks'])}")
        print(f'total {tot:.1f} min')
    elif args.command == 'build':
        for aid in args.allocations or [a['id'] for a in PLAN['allocations']]:
            build(aid, args.cache)
    elif args.command == 'merge':
        merge()
    elif args.command == 'fetch':
        sys.exit(1 if fetch(args.cache, args.allocations) else 0)
    else:
        sys.exit(1 if verify() else 0)


if __name__ == '__main__':
    main()
