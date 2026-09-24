"""MUSCAT manual Owl native-language segments; viewer serves commit-pinned cached assets.

Metadata is read from two pinned Parquet shards by HTTP range (text/path only), not the
hundreds of MB of duplicate multidevice WAVs. Audio URLs from datasets-server contain
that same 40-character commit; downloaded WAV bytes are SHA-pinned in each origin.
"""
import io,re,requests,collections
from functools import lru_cache
import pyarrow.parquet as pq
from common import Candidate,decode,stratified_select,sha_bytes
REPO='goodpiku/muscat-eval';REV='e5e477cc4aeee6b6f5ea65513914b694fb1030f3'
SOURCE=dict(id='muscat',name='MUSCAT evaluation',url='https://huggingface.co/datasets/'+REPO,revision=REV,licence='CC BY 4.0',licenceUrl='https://huggingface.co/datasets/'+REPO+'/blob/'+REV+'/README.md',redistributable=True,released='2026-04',attribution='MUSCAT authors, bilingual scientific conversations, LREC 2026; native speakers.',referenceProduction='Whisper first pass, corrected by speakers; manual segment boundaries and language IDs; one Owl device per spoken event.')
SHARDS={1:'data/train-00001-of-00012.parquet',2:'data/train-00002-of-00012.parquet'}
# lid is the publisher's segment ID, but some de-labelled segments are fully
# English. Require positive target-language lexical evidence and reject an
# English-function-word majority; scientific English nouns may still code-switch.
TARGET_WORDS={
 'de':set('ich du wir ihr er sie es das der die den dem des ein eine einen einem und oder aber ist sind war hat habe hast haben wird werden nicht ja nein auch noch schon so dass weil wenn wie was wo wer von für mit auf bei zu zum zur im am in aus als dann hier doch kann können könnte würde jetzt mal eben mehr sehr vielleicht bitte danke hallo sicher ähm letzte abschnitt punkt nummer'.split()),
 'tr':set('ben sen biz siz bu şu o bir ve veya ama değil için ile gibi var yok mı mi mu mü da de ki ne nasıl neden yani evet hayır çok daha kadar oldu olan olarak sonra çünkü acaba zaten yine şimdi buna bunu selam naber senkronizasyonu hı'.split())}
EN_WORDS=set('the this that these those is are was were and or but for with from to of in on at it you we they he she do did does have has had not no yes a an as by can could would should what why when where how then so if just there here i my your our their word embedding wait token space chain thought paper related work proposed approach'.split())
def _predominantly_target(text,language):
 tokens=re.findall(r"[^\W\d_]+",text.casefold())
 target=sum(t in TARGET_WORDS[language] for t in tokens)
 english=sum(t in EN_WORDS for t in tokens)
 # Short native replies are allowed; zero native evidence is not enough to
 # accept a publisher language label on its own.
 return target>=1 and target>english
class _Range(io.RawIOBase):
 def __init__(self,url,size,ctx):self.url=url;self.size=size;self.pos=0;self.ctx=ctx;self.session=requests.Session()
 def readable(self):return True
 def seekable(self):return True
 def tell(self):return self.pos
 def seek(self,offset,whence=0):self.pos=(offset if whence==0 else self.pos+offset if whence==1 else self.size+offset);return self.pos
 def read(self,n=-1):
  n=self.size-self.pos if n<0 else min(n,self.size-self.pos)
  if n<=0:return b''
  r=self.session.get(self.url,headers={'Range':f'bytes={self.pos}-{self.pos+n-1}'},timeout=(30,120));r.raise_for_status()
  if r.status_code!=206 or len(r.content)!=n:raise ValueError('HF pinned Parquet range not honoured')
  self.pos+=n;self.ctx.note_download(f'range:{self.url}',n);return r.content
@lru_cache(maxsize=2)
def _meta(cache,allocation):
 from common import Context
 ctx=Context(cache,allocation);out={}
 for shard,path in SHARDS.items():
  url=f'https://huggingface.co/datasets/{REPO}/resolve/{REV}/{path}'
  size=int(requests.head(url,allow_redirects=True,timeout=(30,90)).headers['Content-Length'])
  with _Range(url,size,ctx) as stream:
   tab=pq.ParquetFile(stream,pre_buffer=False).read(columns=['device','conv_lang','lid','text','segmentation','audio.path']).to_pylist()
  for i,r in enumerate(tab):
   if r['device']=='owl' and r['segmentation']=='manual':
    out[r['audio']['path']]=(shard,i,shard*299+i,r)
 return out

def candidates(ctx,language):
 manifest=ctx.hf_file(REPO,'data/manual_owl-00000-of-00001.parquet',REV)
 mapping=_meta(str(ctx.cache),ctx.allocation);out=[]
 for r in pq.read_table(manifest).to_pylist():
  if (r['lid']!=language or r['conv_lang']!='en-'+language or not r['text']
      or not _predominantly_target(r['text'],language)):continue
  path=r['audio'];m=re.search(r'_(\d+\.\d+)_(\d+\.\d+)\.wav$',path)
  if not m:continue
  start,end=map(float,m.groups());d=end-start
  # The publisher rounds boundaries to milliseconds; one 1.998 s row is effectively 2 s.
  if d<1.95 or d>30 or re.search(r'\[(?:noise|inaudible|overlap|unk)\]|<unk>',r['text'],re.I):continue
  shard,row,viewer,mr=mapping['manual_owl_'+path.removeprefix('audio/').replace('/','_')]
  if mr['text']!=r['text'] or mr['lid']!=language:raise ValueError('MUSCAT metadata mismatch')
  group=path.split('/')[1]
  out.append(Candidate(key=path.rsplit('/',1)[-1].removesuffix('.wav'),language=language,duration=d,reference=r['text'],referenceType='formatted',group=group,speaker=None,conditions=('spontaneous','far-field:owl','code-switching-context'),stratum=group,origin=dict(repo=REPO,revision=REV,path=SHARDS[shard],row=row,viewerRow=viewer,member=path,start=start,end=end,device='owl',channelPolicy='owl:channel-0',segmentation='manual',sourceSha256=None),extra={}))
 return sorted(out,key=lambda c:c.key)
def select(ctx,cands,target_seconds,language):
 if language=='de':return sorted(cands,key=lambda c:c.key) # just 7.5 min available across 3 conversations
 return stratified_select(cands,target_seconds-3,min_duration=1.95,max_duration=30)
_urls={}
def prepare(ctx,chosen):
 # Batched viewer rows provide short-lived audio links pinned to REV.
 for offset in sorted({(c.origin['viewerRow']//100)*100 for c in chosen}):
  if offset in _urls:continue
  url=f'https://datasets-server.huggingface.co/rows?dataset=goodpiku%2Fmuscat-eval&config=default&split=train&offset={offset}&length=100'
  response=requests.get(url,timeout=(30,90));response.raise_for_status();ctx.note_download(f'viewer:{offset}',len(response.content))
  _urls[offset]={r['row_idx']:r['row'] for r in response.json()['rows']}
 for c in chosen:
  row=c.origin['viewerRow'];r=_urls[(row//100)*100][row]
  if r['device']!='owl' or r['lid']!=c.language or r['text']!=c.reference:raise ValueError(f'MUSCAT viewer row mismatch {row}')
  if f'/{REV}/' not in r['audio'][0]['src']:raise ValueError('MUSCAT viewer audio URL not pinned to dataset commit')

def extract(ctx,cand):
 o=cand.origin;row=o['viewerRow']
 if row//100*100 not in _urls:prepare(ctx,[cand])
 r=requests.get(_urls[row//100*100][row]['audio'][0]['src'],timeout=(30,120));r.raise_for_status();b=r.content;ctx.note_download(f'muscat-audio:{row}',len(b))
 digest=sha_bytes(b)
 if o.get('sourceSha256') and o['sourceSha256']!=digest:raise ValueError(f'MUSCAT pinned WAV mismatch {row}')
 o['sourceSha256']=digest
 return (*decode(b),0)
