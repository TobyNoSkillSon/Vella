"""HiKE Korean–English scripted code-switching test; no speaker IDs in published parquet."""
import hashlib, io
import pyarrow.parquet as pq
import soundfile as sf
from common import Candidate, decode, stratified_select

REPO = 'thetaone-ai/HiKE'
REVISION = '255609b24005e1fcce3f8b3a452260aaf2872cc9'
PARQUET = 'data/test-00000-of-00001.parquet'
SOURCE = dict(
    id='hike', name='HiKE Korean–English code-switching test', url='https://huggingface.co/datasets/thetaone-ai/HiKE',
    revision=REVISION, licence='Apache-2.0',
    licenceUrl='https://huggingface.co/datasets/thetaone-ai/HiKE/blob/255609b24005e1fcce3f8b3a452260aaf2872cc9/README.md',
    redistributable=True, released='2025',
    attribution='HiKE, thetaone-ai; bilingual speakers recorded reviewed, scripted Korean–English sentences.',
    referenceProduction='Published punctuated text and separately supplied lexical text_normalized; no independent spontaneous transcript.',
)


def _parquet(ctx):
    return ctx.hf_file(REPO, PARQUET, REVISION)


def candidates(ctx):
    file = pq.ParquetFile(_parquet(ctx)); out = []
    for rg in range(file.metadata.num_row_groups):
        for idx, row in enumerate(file.read_row_group(rg).to_pylist()):
            audio = row['audio']['bytes']; info = sf.info(io.BytesIO(audio))
            if not 2 <= info.duration <= 30 or not row['text'].strip() or not row['text_normalized'].strip():
                continue
            level = row['cs_level']; category = row['category']
            # Speaker identity is absent in published columns (only sample UUID). Never infer one.
            # Bootstrap therefore resamples clips (13 speakers exist, so CIs are optimistic); one
            # shared group would instead give a zero-width, falsely certain CI.
            out.append(Candidate(key=row['sample_id'], language='ko', duration=info.duration,
                reference=row['text'], lexicalReference=row['text_normalized'], referenceType='formatted',
                group=f"clip-{row['sample_id']}", speaker=None, conditions=('read', 'code-switch:en'),
                stratum=f'{level}/{category}', origin=dict(repo=REPO, revision=REVISION, path=PARQUET,
                    rowGroup=rg, row=idx, sampleId=row['sample_id'], audioSha256=hashlib.sha256(audio).hexdigest(),
                    csLevel=level, category=category), extra={}))
    return sorted(out, key=lambda c: c.key)


def select(ctx, cands, target_seconds):
    return stratified_select(cands, target_seconds, min_duration=2., max_duration=30.)


_group_cache = {}
def extract(ctx, cand):
    rg = cand.origin['rowGroup']
    if rg not in _group_cache:
        _group_cache[rg] = pq.ParquetFile(_parquet(ctx)).read_row_group(rg).to_pylist()
    row = _group_cache[rg][cand.origin['row']]
    audio = row['audio']['bytes']
    if row['sample_id'] != cand.origin['sampleId'] or hashlib.sha256(audio).hexdigest() != cand.origin['audioSha256']:
        raise ValueError('HiKE source row changed')
    samples, rate = decode(audio)
    return samples, rate, 'mean'
