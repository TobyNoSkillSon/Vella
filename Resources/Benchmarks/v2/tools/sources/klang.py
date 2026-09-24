"""Klang Swedish dialect recordings: pinned clean test parquet, unique prompts."""
from functools import lru_cache
import pyarrow.parquet as pq
from common import Candidate,decode,stratified_select,sha_file
REPO='KlangAI/klang-dialects';REV='4117db6f1c53f5c1ca03309ce2a8060b96653708'
PATH='data/sv/clean/test-00001-of-00002.parquet'
SOURCE=dict(id='klang',name='Klang Dialects sv-clean',url='https://huggingface.co/datasets/'+REPO,revision=REV,licence='CC BY 4.0',licenceUrl='https://huggingface.co/datasets/'+REPO+'/blob/'+REV+'/LICENSE',redistributable=True,released='2026-09-14',attribution='Klang AI, Klang Dialects (2026); opt-in Swedish speakers.',referenceProduction='Prompts compared with audio; ASR ensemble/alignment and partial human correction; clean subset excludes ambiguous references.')
@lru_cache(maxsize=2)
def _table(path):return pq.read_table(path)
def candidates(ctx):
 p=ctx.hf_file(REPO,PATH,REV);table=_table(str(p)).drop(['audio']);out=[]
 for ix,r in enumerate(table.to_pylist()):
  text=r['text']; d=r['duration'];speaker=r['speaker']
  if not text or not 2<=d<=30:continue
  out.append(Candidate(key=r['id'],language='sv',duration=d,reference=text,referenceType='formatted',group=speaker,speaker=speaker,conditions=('read','dialect'),stratum=f"{r['region']}-{r['prompt_level']}",origin=dict(repo=REPO,revision=REV,path=PATH,row=ix,promptLevel=r['prompt_level'],region=r['region']),extra={}))
 return sorted(out,key=lambda c:c.key)
def select(ctx,cands,target_seconds):
 # Distinct text and speakers, region and difficulty balanced. A single prompt or reader cannot dominate.
 selected=[]; seen_text=set();seen_speaker=set();total=0
 for c in stratified_select(cands,target_seconds*3,max_duration=30):
  if c.reference in seen_text or c.speaker in seen_speaker:continue
  selected.append(c);seen_text.add(c.reference);seen_speaker.add(c.speaker);total+=c.duration
  if total>=target_seconds:break
 return sorted(selected,key=lambda c:c.key)
def extract(ctx,cand):
 o=cand.origin;p=ctx.hf_file(o['repo'],o['path'],o['revision']);digest=sha_file(p)
 if o.get('parquetSha256') and o['parquetSha256']!=digest:raise ValueError('Klang source hash changed')
 o['parquetSha256']=digest
 row=_table(str(p)).slice(o['row'],1).select(['audio']).to_pylist()[0]['audio'];return (*decode(row['bytes']),'mean')
