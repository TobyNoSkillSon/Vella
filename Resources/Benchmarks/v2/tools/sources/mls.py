"""Official Multilingual LibriSpeech Polish test: both speakers, chapter tar chunks."""
import tarfile
from common import Candidate, decode, stratified_select, sha_file

REPO='facebook/multilingual_librispeech'; REV='2e83e61823b4c47dcbcb1980bb88601274127609'
SOURCE=dict(id='mls',name='Multilingual LibriSpeech',url='https://huggingface.co/datasets/facebook/multilingual_librispeech',revision=REV,licence='CC BY 4.0',licenceUrl='https://www.openslr.org/94/',redistributable=True,released='2020',attribution='Pratap et al., MLS (2020); source LibriVox readers and works.',referenceProduction='Aligned audiobook text; test transcripts were human-listened and corrected.')
_store={}
def _root(config): return f'data/mls_{config}/test'
def candidates(ctx,language,config):
 root=_root(config)
 def lines(file):return ctx.hf_file(REPO,f'{root}/{file}',REV).read_text().splitlines()
 refs=dict(x.split('\t',1) for x in lines('transcripts.txt'))
 out=[]
 for line in lines('segments.txt'):
  uid,src,start,end=line.split('\t');text=refs.get(uid,'').strip(); d=float(end)-float(start)
  if not text or d<2 or d>30:continue
  speaker=uid.split('_')[0];chapter='_'.join(uid.split('_')[:2]);archive=f'{root}/audio/{chapter}_000.tar.gz'
  out.append(Candidate(key=uid,language=language,duration=d,reference=text,referenceType='normalised',group=speaker,speaker=speaker,conditions=('read','audiobook','close-mic'),stratum=speaker,origin=dict(repo=REPO,revision=REV,archive=archive,member=uid+'.flac',sourceUrl=src),extra={}))
 return sorted(out,key=lambda c:c.key)
def select(ctx,cands,target_seconds,language,config):
 return stratified_select(cands,target_seconds,max_group_seconds=target_seconds*.55,min_duration=2,max_duration=30)
def _load(ctx,wanted):
 byarchive={}
 for c in wanted:byarchive.setdefault(c.origin['archive'],set()).add(c.origin['member'])
 for path,members in byarchive.items():
  missing=members-_store.keys()
  if not missing:continue
  with tarfile.open(ctx.hf_file(REPO,path,REV),'r:gz') as t:
   for info in t:
    name=info.name.rsplit('/',1)[-1]
    if name in missing:
     _store[name]=t.extractfile(info).read();missing.remove(name)
     if not missing:break
  if missing:raise ValueError(f'{path}: missing {missing}')
_archive_hash={}
def prepare(ctx,chosen):_load(ctx,chosen)
def extract(ctx,cand):
 member=cand.origin['member'];o=cand.origin
 archive=o['archive'];p=ctx.hf_file(REPO,archive,REV)
 if archive not in _archive_hash:_archive_hash[archive]=sha_file(p)
 if o.get('archiveSha256') and o['archiveSha256']!=_archive_hash[archive]:raise ValueError('MLS archive hash changed')
 o['archiveSha256']=_archive_hash[archive]
 if member not in _store:_load(ctx,[cand])
 try:return (*decode(_store[member]),'mean')
 except Exception:
  # MLS OPUS clips require ffmpeg if libsndfile lacks OPUS for a particular chunk.
  import subprocess,numpy as np
  data=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-f','f64le','-ac','1','-ar','16000','pipe:1'],input=_store[member],capture_output=True,check=True,timeout=30).stdout
  return np.frombuffer(data,dtype='<f8').reshape(-1,1),16000,'mean'
