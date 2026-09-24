"""Three accent/domain-balanced AppTek merged calls, contiguous segment-boundary windows.

Parenthesized vocalizations are spoken, so only their parentheses and partial-word
trailing tilde are removed; non-speech bracket/angle annotations are discarded.
Overlapping turns are ordered by (start, end, speaker_id), with no deduplication.
"""
import json, random, re

from common import Candidate, decode, SEED

REPO = 'apptek-com/apptek_callcenter_dialogues'
REVISION = 'b98967d9946f7f59f58d08624a2a00fe98fe0219'
SOURCE = dict(id='apptek', name='AppTek Call-Center Dialogues', url='https://huggingface.co/datasets/' + REPO,
              revision=REVISION, licence='CC BY-SA 4.0',
              licenceUrl=f'https://huggingface.co/datasets/{REPO}/blob/{REVISION}/README.md',
              redistributable=True, released='2026-04',
              attribution='AppTek, Call-Center Dialogues (2026); role-played customer-service recordings.',
              referenceProduction='Manually transcribed verbatim, diarized turn-level references.')
CALLS = (
    ('en-IN', 'en_IN_Aviation_003_20250917.wav'),
    ('en-US_Aave', 'en_US_Aave_Banking_1591807.wav'),
    ('en-CN', 'en_CN_Travel_1584563.wav'),
)

def _text(t):
    t = re.sub(r'\[[^]]*\]|<[^>]*>', ' ', t)
    # Preserve vocalized fillers inside parentheses; drop only delimiting marks.
    t = t.replace('(', '').replace(')', '').replace('~', '')
    return t


def candidates(ctx):
    out = []
    for accent, name in CALLS:
        path = f'diarization/{accent}/metadata.jsonl'
        rows = [json.loads(line) for line in open(ctx.hf_file(REPO, path, REVISION), encoding='utf-8')]
        row = next(r for r in rows if r['file_name'] == 'audio/' + name)
        segments = sorted(row['segments'], key=lambda s: (s['start'], s['end'], s['speaker_id']))
        # Seeded across accent strata; start/end exactly on annotated turn boundaries.
        rng = random.Random(f'{SEED}-{accent}')
        starts = [i for i, s in enumerate(segments) if s['start'] <= row['duration'] - 420]
        pivot = rng.choice(starts)
        start = segments[pivot]['start']
        ends = [j for j in range(pivot, len(segments)) if 420 <= segments[j]['end'] - start <= 480]
        if not ends:
            raise ValueError(f'{name}: cannot make a 7–8 minute segment-aligned window')
        end_i = min(ends, key=lambda j: (abs(segments[j]['end'] - start - 450), j))
        end = segments[end_i]['end']
        turns = segments[pivot:end_i+1]
        text = ' '.join(_text(s['text']) for s in turns)
        audio = f'diarization/{accent}/{row["file_name"]}'
        out.append(Candidate(key=f'{name[:-4]}-{int(start*1000)}-{int(end*1000)}', language='en',
             duration=end-start, reference=text, referenceType='formatted', group=name,
             conditions=('role-played', 'conversational', 'accented:' + accent, 'long-form'), stratum=accent,
             origin=dict(repo=REPO, revision=REVISION, metadata=path, audio=audio,
                         start=start, end=end, turnStart=pivot, turnEnd=end_i, channel='mean'),
             extra=dict(accent=accent, domain=row['domain'])))
    return sorted(out, key=lambda c:c.key)


def extract(ctx, cand):
    o = cand.origin
    samples, rate = decode(ctx.hf_file(o['repo'], o['audio'], o['revision']), o['start'], o['end'])
    return samples, rate, 'mean'
