"""Polish TEDx natural segments, original published text, never redistributed."""
import csv, re
from common import Candidate, decode, stratified_select, sha_file
REPO='s512757/polish-tedx-asr-eval';REV='d0826bb93d2e268dce45b078e0bae56e7d43af21'
SOURCE=dict(id='polish-tedx',name='Polish TEDx ASR Eval',url='https://huggingface.co/datasets/'+REPO,revision=REV,licence='CC BY-NC-ND 4.0',licenceUrl='https://huggingface.co/datasets/'+REPO+'/blob/'+REV+'/README.md',redistributable=False,released='2026-05-29',attribution='s512757, Polish TEDx ASR Eval (2026); original TEDx Talks speakers/video owners.',referenceProduction='Student-transcribed TEDx talks; only rows with verified_by populated have evidenced second-annotator verification. Raw text preserved.')
# grupa1 timestamps are relative to a different edit of this talk: nine sampled
# segments all disagreed with a completed Polish ASR pass while other talks aligned.
MISALIGNED_TALKS={'0t-sG8FhC4E'}
def candidates(ctx):
 p=ctx.hf_file(REPO,'corpus.csv',REV);out=[];seen=set()
 for r in csv.DictReader(open(p,encoding='utf-8',newline='')):
  file=r['file'];text=r['text'].strip();d=float(r['end'])-float(r['start'])
  talk=r['source_url'].split('v=')[-1].rsplit('/',1)[-1]
  if (talk in MISALIGNED_TALKS or 'tts' in file.lower() or len(text.split())<4
      or not 2<=d<=30 or re.search(r'\[(?:noise|inaudible|overlap|unk)\]|<unk>',text,re.I)):continue
  row_id=(file,r['start'],r['end']);
  if row_id in seen:continue
  seen.add(row_id)
  verified=bool(r['verified_by'].strip())
  out.append(Candidate(key=f"{file.removesuffix('.wav')}-{round(float(r['start'])*1000):08d}-{round(float(r['end'])*1000):08d}",language='pl',duration=d,reference=text,lexicalReference=r['text_norm'] if r['text_norm'].strip() else None,referenceType='formatted',group=talk,speaker=None,conditions=('talk','reverberant'),stratum='verified' if verified else talk,origin=dict(repo=REPO,revision=REV,path='audio/'+file,start=float(r['start']),end=float(r['end']),sourceUrl=r['source_url'],sourceLicense=r['source_license'],verifiedBy=r['verified_by'] or None,verificationStatus='cross-verified' if verified else 'first-pass-only',annotator=r['annotator']),extra={}))
 return sorted(out,key=lambda c:c.key)
# Pinned talk shortlist minimizes whole-WAV transfer while retaining ten independent talks.
TALKS=('0t-sG8FhC4E','2-_tJd9FFK0','4XMKrqabpds','7_OWTJtUK5k','DOIllGDNKw4','cuRVUT3bmek','MYH2qGScEVk','eANk3-vRpCM','f6W_8V7wFJA','owA_Z3navgg')
def select(ctx,cands,target_seconds):
 pool=[c for c in cands if c.group in TALKS]
 # Verified rows occur in one talk; use as many as its 60-second group cap permits,
 # then spread the remainder across independent talks.
 for c in pool:c.stratum=c.group
 verified=sorted((c for c in pool if c.origin['verifiedBy']),key=lambda c:(c.origin['start'],c.origin['end'],c.key))
 remaining=[c for c in pool if not c.origin['verifiedBy']]
 rest=stratified_select(remaining,target_seconds+120,max_group_seconds=60,min_duration=2,max_duration=30)
 first=[];seen={verified[0].group} if verified else set()
 for c in rest:
  if c.group not in seen:first.append(c);seen.add(c.group)
 drawn=verified+first+rest
 chosen=[];seconds=0;group_seconds={}
 for c in drawn:
  if c in chosen:continue
  a,b=c.origin['start'],c.origin['end']
  if group_seconds.get(c.group,0)+c.duration>60:continue
  if any(x.group==c.group and a<x.origin['end']-.05 and x.origin['start']<b-.05 for x in chosen):continue
  chosen.append(c);seconds+=c.duration;group_seconds[c.group]=group_seconds.get(c.group,0)+c.duration
  if seconds>=target_seconds and len(group_seconds)>=6:break
 return sorted(chosen,key=lambda c:c.key)
_source_hash={}
def extract(ctx,cand):
 o=cand.origin;p=ctx.hf_file(o['repo'],o['path'],o['revision'])
 if str(p) not in _source_hash:_source_hash[str(p)]=sha_file(p)
 if o.get('sourceSha256') and o['sourceSha256']!=_source_hash[str(p)]:raise ValueError('TEDx source hash changed')
 o['sourceSha256']=_source_hash[str(p)]
 return (*decode(p,o['start'],o['end']),'mean')
