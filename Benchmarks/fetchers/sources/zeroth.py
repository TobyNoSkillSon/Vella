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
