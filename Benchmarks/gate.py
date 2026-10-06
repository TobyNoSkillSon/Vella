#!/usr/bin/env python3
"""Compare candidate against same-model, same-precision Standard on the identical suite."""
import argparse
import json
from pathlib import Path
import sys
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "scorer/Benchmarks/v2"))
import scoring
TAIL_WORDS = 3

def align_ops(ref, hyp):
    """Per-reference-token ops ('=', 'S', 'D') plus insertion count, following scoring.alignment's choice
    (min cost; ties substitute, then delete, then insert)."""
    n, m = len(ref), len(hyp)
    if n == 0:
        return [], m
    if m == 0:
        return ['D'] * n, 0
    vocab = {}
    r = np.array([vocab.setdefault(x, len(vocab)) for x in ref], dtype=np.int64)
    h = np.array([vocab.setdefault(x, len(vocab)) for x in hyp], dtype=np.int64)
    idx = np.arange(m + 1, dtype=np.int64)
    prev = idx.copy()                           # row 0: all insertions
    choice = np.zeros((n + 1, m + 1), dtype=np.uint8)   # 0 sub, 1 del, 2 ins
    choice[0, 1:] = 2
    for i in range(1, n + 1):
        sub = np.empty(m + 1, dtype=np.int64); sub[0] = 1 << 40
        sub[1:] = prev[:-1] + (h != r[i - 1])
        dele = prev + 1
        cand = np.minimum(sub, dele)
        row = np.minimum.accumulate(cand - idx) + idx   # row[j] = min(cand[j], row[j-1] + 1)
        c = np.full(m + 1, 2, dtype=np.uint8)
        c[dele == row] = 1
        c[sub == row] = 0
        choice[i] = c
        prev = row
    ops = []; ins = 0; i, j = n, m
    while i > 0 or j > 0:
        c = choice[i, j] if i > 0 else 2
        if c == 0:
            ops.append('=' if r[i - 1] == h[j - 1] else 'S'); i -= 1; j -= 1
        elif c == 1:
            ops.append('D'); i -= 1
        else:
            ins += 1; j -= 1
    ops.reverse()
    return ops, ins

def trailing_deletions(ops):
    k = 0
    for op in reversed(ops):
        if op != 'D': break
        k += 1
    return k

def lost_clips(base, cand, langs, spans_out=None):
    """Clips C lost where B had >= TAIL_WORDS reference words right: empty hypothesis or a deleted tail."""
    lost = []; spans = 0
    bmap = {r['id']: r for r in base['clips']}
    for rc in cand['clips']:
        if rc['language'] != 'en' and rc['language'] not in langs: continue
        rb = bmap[rc['id']]
        if rc['units'] == 0: continue
        cops, bops = rc['ops'], rb['ops']
        if rc['hyp_units'] == 0:
            had = bops.count('=')
            if had >= TAIL_WORDS:
                lost.append({'id': rc['id'], 'kind': 'empty', 'lost': had, 'units': rc['units']})
            continue
        t = rc['tail_del']
        had = sum(1 for k in range(len(cops) - t, len(cops)) if bops[k] == '=')
        if had >= TAIL_WORDS:
            lost.append({'id': rc['id'], 'kind': 'tail', 'lost': had, 'units': rc['units']})
        # Advisory: runs of >= TAIL_WORDS consecutive reference words that B got right and C deleted (mid-clip loss).
        run = 0
        for k in range(len(cops) + 1):
            if k < len(cops) and cops[k] == 'D' and bops[k] == '=':
                run += 1; continue
            if run >= TAIL_WORDS: spans += 1
            run = 0
    if spans_out is not None: spans_out.append(spans)
    return lost


def compare(base, candidate, base_raw=None, candidate_raw=None, manifest=None):
    for key in ('modelID', 'suiteID', 'scoringVersion', 'scorerSHA256'):
        if base[key] != candidate[key]:
            raise ValueError('baseline identity mismatch: ' + key)
    if [c['id'] for c in base['clips']] != [c['id'] for c in candidate['clips']]:
        raise ValueError('clip layout differs')
    for key in ('precision', 'transport', 'sessionLayout'):
        if base_raw.get(key) != candidate_raw.get(key):
            raise ValueError('baseline raw identity mismatch: ' + key)
    delta = (candidate['words']['rate'] - base['words']['rate']) * 100
    failures = []
    if delta > .1 + 1e-10:
        failures.append('English WER exceeds stock by > 0.1 point')
    fmt = (candidate['formatting']['rate'] - base['formatting']['rate']) * 100
    if fmt > .1 + 1e-10:
        failures.append('format CER exceeds stock by > 0.1 point')
    lost = []
    diagnostics = {}
    for lang, b in candidate['multilingual']['languages'].items():
        a = base['multilingual']['languages'][lang]
        if b.get('status') == 'supported' and a.get('rate') is not None:
            diagnostics[lang] = (b['rate'] - a['rate']) * 100
    if manifest is not None:
        published = json.loads((Path(__file__).resolve().parents[1] / 'Resources/benchmarks.json').read_text())
        noise = published['noise_floor']['families'].get(base['modelID'], {})
        ml_tolerance = noise.get('tolerance_ml_pt', .1)
        ml_delta = sum(diagnostics.values()) / len(diagnostics) if diagnostics else None
        if ml_delta is not None and ml_delta > ml_tolerance + 1e-10:
            failures.append('supported-language mean exceeds published family tolerance')
        for lang, delta_lang in diagnostics.items():
            minutes = sum(c['samples'] for c in manifest['clips'] if c['language'] == lang) / 16000 / 60
            if minutes >= 5 and delta_lang > 2 + 1e-10:
                failures.append(lang + ' exceeds +2 points on >= 5 audio minutes')
        def analyze(raw):
            predictions = {c['id']: c['transcript'] for c in raw['clips']}
            if len(predictions) != len(raw['clips']) or set(predictions) != {c['id'] for c in manifest['clips']}:
                raise ValueError('raw result IDs differ from manifest')
            rows = []
            for clip in manifest['clips']:
                lang = clip['language']
                tokenize = scoring.english_tokens if lang == 'en' else lambda t: scoring.multilingual_tokens(t, lang)
                ref = tokenize(clip.get('lexicalReference', clip['reference']))
                hyp = tokenize(predictions[clip['id']])
                ops, _ = align_ops(ref, hyp)
                rows.append({'id': clip['id'], 'language': lang, 'units': len(ref), 'hyp_units': len(hyp),
                             'ops': ''.join(ops), 'tail_del': trailing_deletions(ops)})
            return {'clips': rows}
        langs = set(diagnostics)
        spans = []
        lost = lost_clips(analyze(base_raw), analyze(candidate_raw), langs, spans)
        if lost:
            failures.append('empty clip or deleted tail containing >= 3 reference words stock got right')
    else:
        raise ValueError('raw hypotheses and manifest required for lost-tail check')
    return {'pass': not failures, 'english_wer_delta_pt': delta, 'format_cer_delta_pt': fmt,
            'lost_clips': lost, 'language_delta_pt': diagnostics, 'multilingual_mean_delta_pt': ml_delta, 'multilingual_tolerance_pt': ml_tolerance, 'lost_spans_advisory': spans[0], 'reasons': failures,
            'quality_label': 'full' if base['suiteID'] == 'vella-v2' else 'estimate; screening only'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('standard_score', type=Path)
    p.add_argument('candidate_score', type=Path)
    p.add_argument('--standard-pass', type=Path, required=True)
    p.add_argument('--candidate-pass', type=Path, required=True)
    p.add_argument('--suite', choices=['quick', 'full'], default='full')
    a = p.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'suites' / ('v2-quick' if a.suite == 'quick' else 'v2') / 'manifest.json').read_text())
    base = json.loads(a.standard_score.read_text()); candidate = json.loads(a.candidate_score.read_text())
    base_raw = json.loads(a.standard_pass.read_text()); candidate_raw = json.loads(a.candidate_pass.read_text())
    support = json.loads((root / 'scorer/support.json').read_text())
    for score, raw in ((base, base_raw), (candidate, candidate_raw)):
        expected = scoring.score(manifest, raw, support, 0)
        if any(score[k] != expected[k] for k in ('clips', 'words', 'formatting', 'multilingual')):
            raise ValueError('score does not match raw hypotheses and frozen manifest')
    result = compare(base, candidate, base_raw, candidate_raw, manifest)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['pass'] else 1)


if __name__ == '__main__':
    main()
