"""Official Multilingual LibriSpeech Polish test: both speakers, chapter tar chunks."""
import tarfile
from common import Candidate, decode, stratified_select, sha_file

REPO='facebook/multilingual_librispeech'; REV='2e83e61823b4c47dcbcb1980bb88601274127609'
SOURCE=dict(id='mls',name='Multilingual LibriSpeech',url='https://huggingface.co/datasets/facebook/multilingual_librispeech',revision=REV,licence='CC BY 4.0',licenceUrl='https://www.openslr.org/94/',redistributable=True,released='2020',attribution='Pratap et al., MLS (2020); source LibriVox readers and works.',referenceProduction='Aligned audiobook text; test transcripts were human-listened and corrected.')
_store={}
def _root(config): return f'data/mls_{config}/test'
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
