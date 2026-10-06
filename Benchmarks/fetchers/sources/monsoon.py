"""Monsoon en-IN public test, row-group range reads on a single pinned shard.

One utterance per speaker, seeded and round-robin over native state/gender.
No markup is removed; utterances containing annotation delimiters are excluded.
"""
import re
import pyarrow.parquet as pq
from common import Candidate, decode, stratified_select

REPO='VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN'
REVISION='bc1da7b42ef6e2853123c97bf6d22067e4802d11'
PATH='data/test-00000-of-00004.parquet'
SOURCE=dict(id='monsoon',name='Monsoon en-IN public test',url='https://huggingface.co/datasets/'+REPO,
 revision=REVISION,licence='CC BY 4.0',licenceUrl=f'https://huggingface.co/datasets/{REPO}/blob/{REVISION}/README.md',
 redistributable=True,released='2026-08-28',attribution='VoiceArena, Monsoon en-IN public test (2026).',
 referenceProduction='ASR drafts corrected and independently checked by native-speaking linguists.')
# Two bounded row groups provide more than 15 minutes while using <~160MB of parquet audio.
GROUPS=(0,1)
_audio={}

def _open(ctx):
    return ctx.hf_open(REPO, PATH, REVISION)



def prepare(ctx,chosen):
    for rg in sorted({c.origin['rowGroup'] for c in chosen}):
        if rg in _audio:continue
        with _open(ctx) as f:
            p=pq.ParquetFile(f)
            # Bytes only, not redundant metadata; range reads one parquet column chunk.
            t=p.read_row_group(rg,columns=['audio.bytes'])
            _audio[rg]=t.column(0).combine_chunks().field('bytes').to_pylist()

def extract(ctx,cand):
    rg=cand.origin['rowGroup']
    if rg not in _audio:prepare(ctx,[cand])
    samples,rate=decode(_audio[rg][cand.origin['row']])
    return samples,rate,'mean'
