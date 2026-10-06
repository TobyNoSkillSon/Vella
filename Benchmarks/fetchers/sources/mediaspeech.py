"""MediaSpeech via pinned per-language HF mirror, one shard per language. Original video rights unclear."""
import io,hashlib,re
from functools import lru_cache
import soundfile as sf
import pyarrow.parquet as pq
from common import Candidate,decode,stratified_select,sha_file,clean_text
REPO='ymoslem/MediaSpeech';REV='4008a968760f2187b0c5b2b2db965f1283433059'
SOURCE=dict(id='mediaspeech',name='MediaSpeech (per-language HF mirror)',url='https://www.openslr.org/108/',revision=REV,licence='CC BY 4.0 dataset; original videos retain owners’ copyright',licenceUrl='https://github.com/NTRLab/MediaSpeech',redistributable=False,released='2021',attribution='Kolobov et al., MediaSpeech (2021); original YouTube video owners. HF mirror ymoslem/MediaSpeech.',referenceProduction='Two manual annotators and third disagreement resolver; postprocessed lexical sentences. HF mirror strips original video/channel identifiers.')
@lru_cache(maxsize=3)
def _table(path):return pq.read_table(path)
def _file(ctx,lang):
 path=f'{lang}/train-00000-of-00002.parquet';p=ctx.hf_file(REPO,path,REV);return path,p

_tr_audio={};_tr_urls={};TR_SHA='1ef4556b76a86785da6d9b7e40897df66719adcd325ff9ebe6380e3f8f0e8061'
def _viewer(ctx,language,row):
 if row not in _tr_urls:
  offset=(row//100)*100
  url=f'https://datasets-server.huggingface.co/rows?dataset=ymoslem%2FMediaSpeech&config={language}&split=train&offset={offset}&length=100'
  response=ctx.http_request(url);ctx.note_download(f'mediaspeech-viewer:{language}:{offset}',len(response.content))
  for r in response.json()['rows']:
   source=r['row']['audio'][0]['src']
   if f'/{REV}/' not in source:raise ValueError('MediaSpeech viewer revision mismatch')
   _tr_urls[r['row_idx']]=(source,r['row']['sentence'])
 return _tr_urls[row]
def _tr_data(ctx,row):
 if row not in _tr_audio:
  url,_=_viewer(ctx,'tr',row);r=ctx.http_request(url)
  ctx.note_download(f'mediaspeech-audio:tr:{row}',len(r.content));_tr_audio[row]=r.content
 return _tr_audio[row]
def _tr_candidates(ctx):
 from sources.muscat import _Range
 path='tr/train-00000-of-00002.parquet'
 url=f'https://huggingface.co/datasets/{REPO}/resolve/{REV}/{path}'
 with _Range(url,311903314,ctx) as f:
  rows=pq.ParquetFile(f,pre_buffer=False).read(columns=['sentence','audio.path']).to_pylist()
 out=[]
 for ix in range(0,len(rows),19):
  r=rows[ix];text=r['sentence'];file=r['audio']['path']
  if not text or re.search(r'\[(?:noise|inaudible|overlap|unk)\]|<unk>',text,re.I):continue
  b=_tr_data(ctx,ix);d=sf.info(io.BytesIO(b)).duration
  if not 2<=d<=30:continue
  if _viewer(ctx,'tr',ix)[1]!=text:raise ValueError('MediaSpeech mirrored sentence mismatch')
  out.append(Candidate(key=file.removesuffix('.flac'),language='tr',duration=d,reference=text,referenceType='normalised',group=f'tr-{file}',speaker=None,conditions=('media','youtube'),stratum=str(ix//100),origin=dict(repo=REPO,revision=REV,path=path,parquetSha256=TR_SHA,row=ix,member=file,memberSha256=hashlib.sha256(b).hexdigest(),upstream='OpenSLR SLR108 v1.1',viewer=True),extra={}))
 return sorted(out,key=lambda c:c.key)
def extract(ctx,cand):
 o=cand.origin
 if o.get('viewer'):
  b=_tr_data(ctx,o['row'])
  if clean_text(_viewer(ctx,'tr',o['row'])[1])!=cand.reference:raise ValueError('MediaSpeech viewer reference mismatch')
  if hashlib.sha256(b).hexdigest()!=o['memberSha256']:raise ValueError('MediaSpeech viewer audio mismatch')
  return (*decode(b),'mean')
 p=ctx.hf_file(o['repo'],o['path'],o['revision'])
 if sha_file(p)!=o['parquetSha256']:raise ValueError('MediaSpeech archive SHA-256 mismatch')
 b=_table(str(p)).slice(o['row'],1).select(['audio']).to_pylist()[0]['audio']['bytes']
 if hashlib.sha256(b).hexdigest()!=o['memberSha256']:raise ValueError('MediaSpeech audio SHA-256 mismatch')
 return (*decode(b),'mean')
