"""NOTSOFAR eval-small GT: one sc_meetup_0/ch0 far-field device per meeting.

Windows serialize overlapping utterances by (start,end,speaker); unknown speech is omitted,
not guessed. Independent turn clips have no other speaker interval intersecting their span.
"""
import json, re
from common import Candidate, decode

REPO='microsoft/NOTSOFAR'; REV='ba8fd0f034ce185fe4d24f47e53b4b8194795f07'
BASE='benchmark-datasets/eval_set/240629.1_eval_small_with_GT/MTG'
MEETINGS=('MTG_32000','MTG_32003','MTG_32004')
SOURCE=dict(id='notsofar',name='NOTSOFAR-1 eval-small with GT',url='https://huggingface.co/datasets/microsoft/NOTSOFAR',revision=REV,
 licence='CC BY 4.0',licenceUrl=f'https://huggingface.co/datasets/microsoft/NOTSOFAR/blob/{REV}/LICENSE.txt',redistributable=True,
 released='2024 challenge; GT subsequently released',attribution='Microsoft, NOTSOFAR-1 dataset; CC BY 4.0.',
 referenceProduction='Speaker-labelled, time-aligned human GT; lexical text is published transcription with non-speech tags removed.')

def _text(t):
    if re.search(r'<(?:UNKNOWN|ISSUE|BA|FL)/>',t,re.I): return ''
    # ST, FILL, FILLlaugh are nonlexical tags; PName delimiters surround actual words.
    return re.sub(r'<[^>]+>', '', t).strip()

def _make(meet, rows, start,end,kind):
    chosen=[r for r in rows if r['start_time']>=start-1e-6 and r['end_time']<=end+1e-6]
    chosen.sort(key=lambda r:(r['start_time'],r['end_time'],r['speaker_id']))
    ref=' '.join(filter(None,(_text(r['text']) for r in chosen)))
    if not ref: return None
    path=f'{BASE}/{meet}/sc_meetup_0/ch0.wav'
    return Candidate(key=f'{meet}-{kind}-{start:.2f}-{end:.2f}',language='en',duration=end-start,
     reference=ref,referenceType='formatted',group=meet,conditions=('meeting','far-field','overlap' if kind=='window' else 'isolated-turn'),
     stratum=meet,origin=dict(repo=REPO,revision=REV,path=path,channel='sc_meetup_0/ch0.wav',start=start,end=end,referencePath=f'{BASE}/{meet}/gt_transcription.json'),
     extra=dict(meeting=meet,kind=kind,segments=len(chosen)))

def candidates(ctx):
    out=[]; turns=[]
    for meet in MEETINGS:
        base=f'{BASE}/{meet}'
        rows=json.loads(ctx.hf_file(REPO,f'{base}/gt_transcription.json',REV).read_text())
        rows=sorted(rows,key=lambda r:(r['start_time'],r['end_time'],r['speaker_id']))
        # Window starts at first annotated segment; choose an end near 265 s at a gap
        # with no segment crossing the boundary (never mid-word).
        start=rows[0]['start_time']; target=start+295
        ends=[r['end_time'] for r in rows if 275 <= r['end_time']-start <= 320
              and not any(q['start_time']<r['end_time']<q['end_time'] for q in rows)]
        end=min(ends,key=lambda x:(abs(x-target),x))
        out.append(_make(meet,rows,start,end,'window'))
        for r in rows:
            a,b=r['start_time'],r['end_time']; text=_text(r['text'])
            if a<end or b-a<2 or b-a>30 or not text: continue
            if any(q is not r and q['start_time']<b and q['end_time']>a for q in rows): continue
            c=_make(meet,[r],a,b,'turn')
            if c: turns.append(c)
    # Fill remaining time with unique isolated turns, interleaved across meetings.
    turns.sort(key=lambda c:(c.origin['start'],c.group,c.key))
    target=900; total=sum(c.duration for c in out)
    for c in turns:
        if total>=target-2: break
        if total+c.duration>target+5: continue
        out.append(c);total+=c.duration
    return sorted(out,key=lambda c:c.key)

def select(ctx,cands,target_seconds): return cands

def extract(ctx,cand):
    o=cand.origin; path=ctx.hf_file(o['repo'],o['path'],o['revision'])
    samples,rate=decode(path,o['start'],o['end'])
    return samples,rate,0
