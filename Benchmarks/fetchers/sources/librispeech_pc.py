"""LibriSpeech-PC printed orthography over disjoint test-other LibriSpeech recordings."""
import json, tarfile, hashlib
from pathlib import Path
import pyarrow.parquet as pq
from common import Candidate, decode, stratified_select

REPO='openslr/librispeech_asr'; REV='2b9f39377850ffce6bf6358257ae9f84b2349497'
PARQUET='other/test/0000.parquet'
MANIFEST='https://www.openslr.org/resources/145/manifests.tar.gz'
MANIFEST_SHA='96d4eae2222b29b66437a21959252419bcd4762e5042e71e023790171054d1c0'
SOURCE=dict(id='librispeech-pc',name='LibriSpeech-PC test-other',url='https://www.openslr.org/145/',revision=f'OpenSLR145 manifests sha256:{MANIFEST_SHA}; {REPO} parquet@{REV}',licence='CC BY 4.0',licenceUrl='https://www.openslr.org/resources/145/about.html',redistributable=True,released='2023',attribution='Meister et al., LibriSpeech-PC; LibriSpeech / OpenSLR 12 audio.',referenceProduction='Printed source-book text aligned by researchers to LibriSpeech; text_raw keeps original orthography, text is ASR-normalized.')

def _manifest(ctx):
    arc=ctx.http_file(MANIFEST,MANIFEST_SHA,name='librispeech-pc-manifests.tar.gz')
    with tarfile.open(arc) as t:
        return [json.loads(line) for line in t.extractfile('test-other.json')]

def _audio_index(ctx):
    with ctx.hf_open(REPO,PARQUET,REV) as f:
        p=pq.ParquetFile(f); out={}
        for rg in range(p.metadata.num_row_groups):
            for ix, row in enumerate(p.read_row_group(rg,columns=['id','speaker_id']).to_pylist()):
                out[row['id']]=(rg,ix,str(row['speaker_id']))
    return out



def prepare(ctx,chosen):
    groups={}
    for c in chosen:
        path=ctx.cache/'librispeech_pc'/f'{c.key}.bin'
        if not path.exists(): groups.setdefault(c.origin['rowGroup'],[]).append(c)
    if not groups: return
    with ctx.hf_open(REPO,PARQUET,REV) as f:
        p=pq.ParquetFile(f)
        for rg,cands in sorted(groups.items()):
            table=p.read_row_group(rg,columns=['audio','id']).to_pylist()
            for c in cands:
                row=table[c.origin['row']]
                if row['id']!=c.key: raise ValueError('parquet row ID mismatch')
                data=row['audio']['bytes']; path=ctx.cache/'librispeech_pc'/f'{c.key}.bin'
                path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data)

def extract(ctx,cand):
    path=ctx.cache/'librispeech_pc'/f'{cand.key}.bin'
    if not path.exists(): prepare(ctx,[cand])
    data=path.read_bytes(); digest=hashlib.sha256(data).hexdigest()
    if cand.origin.get('sourceSha256') and digest!=cand.origin['sourceSha256']: raise ValueError('source hash mismatch')
    cand.origin['sourceSha256']=digest
    a,rate=decode(data)
    return a,rate,'mean'
