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




def extract(ctx, cand):
    o = cand.origin
    samples, rate = decode(ctx.hf_file(o['repo'], o['audio'], o['revision']), o['start'], o['end'])
    return samples, rate, 'mean'
