"""Official Zeroth-Korean test utterances in a pinned public test-only parquet mirror."""
import hashlib, io
import pyarrow.parquet as pq
import soundfile as sf
from common import Candidate, decode, stratified_select

REPO = 'kresnik/zeroth_korean'
REVISION = '1fe937899f828af822293d05e086200946088bdf'
PARQUET = 'data/test-00000-of-00001.parquet'
SOURCE = dict(
    id='zeroth', name='Zeroth-Korean official test', url='https://www.openslr.org/40/',
    revision=REVISION, licence='CC BY 4.0', licenceUrl='https://www.openslr.org/40/',
    redistributable=True, released='2017',
    attribution='Zeroth-Korean, OpenSLR SLR40; test-only parquet redistributed by kresnik/zeroth_korean.',
    referenceProduction='Published official read-speech transcript, unpunctuated Korean orthography.',
)


def _parquet(ctx):
    return ctx.hf_file(REPO, PARQUET, REVISION)


def candidates(ctx):
    file = pq.ParquetFile(_parquet(ctx)); out = []
    for rg in range(file.metadata.num_row_groups):
        rows = file.read_row_group(rg).to_pylist()
        for idx, row in enumerate(rows):
            audio = row['audio']['bytes']; info = sf.info(io.BytesIO(audio))
            if not 2 <= info.duration <= 30 or not row['text'].strip():
                continue
            speaker = str(row['speaker_id'])
            out.append(Candidate(key=row['id'], language='ko', duration=info.duration,
                reference=row['text'], referenceType='normalised', group=f'speaker-{speaker}',
                speaker=speaker, conditions=('read',), stratum=speaker,
                origin=dict(repo=REPO, revision=REVISION, path=PARQUET,
                    rowGroup=rg, row=idx, id=row['id'], audioSha256=hashlib.sha256(audio).hexdigest()), extra={}))
    return sorted(out, key=lambda c: c.key)


def select(ctx, cands, target_seconds):
    return stratified_select(cands, target_seconds, max_group_seconds=37., min_duration=2., max_duration=30.)


_group_cache = {}
def extract(ctx, cand):
    rg = cand.origin['rowGroup']
    if rg not in _group_cache:
        _group_cache[rg] = pq.ParquetFile(_parquet(ctx)).read_row_group(rg).to_pylist()
    row = _group_cache[rg][cand.origin['row']]
    audio = row['audio']['bytes']
    if row['id'] != cand.origin['id'] or hashlib.sha256(audio).hexdigest() != cand.origin['audioSha256']:
        raise ValueError('Zeroth source row changed')
    samples, rate = decode(audio)
    return samples, rate, 'mean'
