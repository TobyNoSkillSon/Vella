"""Polish TEDx natural segments, original published text, never redistributed."""
import csv, re
from common import Candidate, decode, stratified_select, sha_file
REPO='s512757/polish-tedx-asr-eval';REV='d0826bb93d2e268dce45b078e0bae56e7d43af21'
SOURCE=dict(id='polish-tedx',name='Polish TEDx ASR Eval',url='https://huggingface.co/datasets/'+REPO,revision=REV,licence='CC BY-NC-ND 4.0',licenceUrl='https://huggingface.co/datasets/'+REPO+'/blob/'+REV+'/README.md',redistributable=False,released='2026-05-29',attribution='s512757, Polish TEDx ASR Eval (2026); original TEDx Talks speakers/video owners.',referenceProduction='Student-transcribed TEDx talks; only rows with verified_by populated have evidenced second-annotator verification. Raw text preserved.')
# grupa1 timestamps are relative to a different edit of this talk: nine sampled
# segments all disagreed with a completed Polish ASR pass while other talks aligned.
MISALIGNED_TALKS={'0t-sG8FhC4E'}
# Pinned talk shortlist minimizes whole-WAV transfer while retaining ten independent talks.
TALKS=('0t-sG8FhC4E','2-_tJd9FFK0','4XMKrqabpds','7_OWTJtUK5k','DOIllGDNKw4','cuRVUT3bmek','MYH2qGScEVk','eANk3-vRpCM','f6W_8V7wFJA','owA_Z3navgg')
_source_hash={}
def extract(ctx,cand):
 o=cand.origin;p=ctx.hf_file(o['repo'],o['path'],o['revision'])
 if str(p) not in _source_hash:_source_hash[str(p)]=sha_file(p)
 if o.get('sourceSha256') and o['sourceSha256']!=_source_hash[str(p)]:raise ValueError('TEDx source hash changed')
 o['sourceSha256']=_source_hash[str(p)]
 return (*decode(p,o['start'],o['end']),'mean')
