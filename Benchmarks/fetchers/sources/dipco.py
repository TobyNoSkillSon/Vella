"""DiPCo S06 eval, one distant U04 CH1. Chronological multi-speaker window reference."""
import json,re
from common import Candidate,decode
REPO='huckiyang/DiPCo';REV='e2b29d3d0d88692c744feb15e290f7316b68014e'
AUDIO='audio/eval/S06_U04.CH1.wav';TRANS='transcriptions/eval/S06.json'
SOURCE=dict(id='dipco',name='DiPCo S06 eval',url='https://huggingface.co/datasets/huckiyang/DiPCo',revision=REV,
 licence='CDLA-Permissive-1.0',licenceUrl=f'https://huggingface.co/datasets/huckiyang/DiPCo/blob/{REV}/README.md',redistributable=True,
 released='2019 corpus; 2023 mirror',attribution='DiPCo corpus, Dinner Party Corpus; huckiyang/DiPCo mirror.',
 referenceProduction='Manual close-talk-derived speaker transcripts, timestamped JSON. Inference uses only distant U04 CH1.')

def _seconds(t):
    h,m,s=t.split(':');return int(h)*3600+int(m)*60+float(s)
def _text(t):
    if '[unintelligible]' in t.lower():return ''
    return re.sub(r'\[noise\]','',t,flags=re.I).strip()
def _make(rows,a,b,kind):
    chosen=sorted((r for r in rows if r['a']>=a-1e-6 and r['b']<=b+1e-6),key=lambda r:(r['a'],r['b'],r['speaker_id']))
    ref=' '.join(filter(None,(_text(r['words']) for r in chosen)))
    if not ref:return None
    return Candidate(key=f'S06-{kind}-{a:.2f}-{b:.2f}',language='en',duration=b-a,reference=ref,referenceType='normalised',group='S06',
      conditions=('meeting','far-field','music' if a>=377 else 'dinner-conversation'),stratum=kind,
      origin=dict(repo=REPO,revision=REV,path=AUDIO,referencePath=TRANS,channel='U04 CH1',start=a,end=b),extra=dict(kind=kind,segments=len(chosen)))
def extract(ctx,cand):
    o=cand.origin;samples,rate=decode(ctx.hf_file(o['repo'],o['path'],o['revision']),o['start'],o['end'])
    return samples,rate,0
