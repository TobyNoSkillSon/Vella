"""Klang Swedish dialect recordings: pinned clean test parquet, unique prompts."""
from functools import lru_cache
import pyarrow.parquet as pq
from common import Candidate,decode,stratified_select,sha_file
REPO='KlangAI/klang-dialects';REV='4117db6f1c53f5c1ca03309ce2a8060b96653708'
PATH='data/sv/clean/test-00001-of-00002.parquet'
SOURCE=dict(id='klang',name='Klang Dialects sv-clean',url='https://huggingface.co/datasets/'+REPO,revision=REV,licence='CC BY 4.0',licenceUrl='https://huggingface.co/datasets/'+REPO+'/blob/'+REV+'/LICENSE',redistributable=True,released='2026-09-14',attribution='Klang AI, Klang Dialects (2026); opt-in Swedish speakers.',referenceProduction='Prompts compared with audio; ASR ensemble/alignment and partial human correction; clean subset excludes ambiguous references.')
@lru_cache(maxsize=2)
def _table(path):return pq.read_table(path)
def extract(ctx,cand):
 o=cand.origin;p=ctx.hf_file(o['repo'],o['path'],o['revision']);digest=sha_file(p)
 if o.get('parquetSha256') and o['parquetSha256']!=digest:raise ValueError('Klang source hash changed')
 o['parquetSha256']=digest
 row=_table(str(p)).slice(o['row'],1).select(['audio']).to_pylist()[0]['audio'];return (*decode(row['bytes']),'mean')
