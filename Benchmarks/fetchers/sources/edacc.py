"""EdAcc test dyads: bounded parquet row-group reads, speaker-capped L1/accent sample.

Uppercase lexical references retain spoken hesitations. Angle-bracketed non-speech
annotations (<LAUGH>, <DTMF>, etc.) are stripped; clips with uncertain/overlap
annotation are excluded rather than guessing their words.
"""
import io,re
import soundfile as sf
import pyarrow.parquet as pq
from common import Candidate, decode, stratified_select

REPO='edinburghcstr/edacc'
REVISION='d9ae7bd344f0562b766ec93ee5ce8f2f9568ce66'
SOURCE=dict(id='edacc',name='EdAcc',url='https://huggingface.co/datasets/'+REPO,
 revision=REVISION,licence='CC BY-SA 4.0',licenceUrl=f'https://huggingface.co/datasets/{REPO}/blob/{REVISION}/README.md',
 redistributable=True,released='2023',attribution='University of Edinburgh CSTR, EdAcc (2023).',
 referenceProduction='Professionally transcribed speaker turns with disfluencies and non-speech annotations.')
PATHS=(
 'data/test-00000-of-00010-f0aceb1ca4406ff1.parquet',
 'data/test-00001-of-00010-856b016d9d438ff3.parquet',
 'data/test-00002-of-00010-2b021baedb4deb8a.parquet',
 'data/test-00003-of-00010-4de275e704375a02.parquet',
 'data/test-00004-of-00010-806407c9bc68112a.parquet',
 'data/test-00005-of-00010-9c97c4c4c8d01f82.parquet',
 'data/test-00006-of-00010-cc4648d0f66f65a4.parquet',
 'data/test-00007-of-00010-ea5ed4464ecff3c9.parquet',
)
GROUPS=(0,4)
_audio={}
# Publisher scoring directives and annotation tokens are not utterances. Reject the
# entire turn rather than turning a scoring directive into a lexical reference.
_CONTROL=re.compile(r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b|<[^>]*>|\[[^]]*\]|\{[^}]*\}')

def _load(ctx,path,rg):
    key=(path,rg)
    if key not in _audio:
        with ctx.hf_open(REPO,path,REVISION) as f:
            p=pq.ParquetFile(f)
            table=p.read_row_group(rg)
        rows=table.to_pylist()
        _audio[key]=[r['audio']['bytes'] for r in rows]
        return rows
    return None



def prepare(ctx,chosen):
    for path,rg in sorted({(c.origin['parquet'],c.origin['rowGroup']) for c in chosen}):
        if (path,rg) not in _audio:_load(ctx,path,rg)

def extract(ctx,cand):
    o=cand.origin;key=(o['parquet'],o['rowGroup'])
    if key not in _audio:prepare(ctx,[cand])
    samples,rate=decode(_audio[key][o['row']])
    return samples,rate,'mean'
