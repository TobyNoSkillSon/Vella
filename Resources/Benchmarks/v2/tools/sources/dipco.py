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
def candidates(ctx):
    rows=json.loads(ctx.hf_file(REPO,TRANS,REV).read_text())
    for r in rows:r['a']=_seconds(r['start_time']['U04']);r['b']=_seconds(r['end_time']['U04'])
    rows.sort(key=lambda r:(r['a'],r['b'],r['speaker_id']))
    # Two disjoint windows: first before music at 06:17, second during music.
    # Boundary choices never bisect a timestamped segment.
    windows=[]
    for lo,hi in ((rows[0]['a'],355),(390,750)):
        starts=[r['a'] for r in rows if lo<=r['a']<=lo+20 and not any(q['a']<r['a']<q['b'] for q in rows)]
        a=min(starts) if starts else lo
        ends=[r['b'] for r in rows if hi-15<=r['b']<=hi+15 and not any(q['a']<r['b']<q['b'] for q in rows)]
        b=min(ends,key=lambda x:(abs(x-hi),x))
        windows.append(_make(rows,a,b,'window'))
    out=[x for x in windows if x]; total=sum(x.duration for x in out)
    # Non-overlapping isolated turns outside both windows, biased early before music.
    for r in rows:
        a,b=r['a'],r['b']
        if total>=720-2:break
        if not (2<=b-a<=30) or not _text(r['words']):continue
        if any(a<x.origin['end'] and b>x.origin['start'] for x in windows):continue
        if any(q is not r and q['a']<b and q['b']>a for q in rows):continue
        if total+b-a>725:continue
        x=_make([r],a,b,'turn')
        if x:out.append(x);total+=x.duration
    return sorted(out,key=lambda c:c.key)
def select(ctx,cands,target_seconds):return cands
def extract(ctx,cand):
    o=cand.origin;samples,rate=decode(ctx.hf_file(o['repo'],o['path'],o['revision']),o['start'],o['end'])
    return samples,rate,0
