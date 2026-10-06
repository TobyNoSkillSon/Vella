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



def extract(ctx,cand):
    o=cand.origin; path=ctx.hf_file(o['repo'],o['path'],o['revision'])
    samples,rate=decode(path,o['start'],o['end'])
    return samples,rate,0
