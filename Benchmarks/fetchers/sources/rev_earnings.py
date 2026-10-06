"""Rev human verbatim orthography, with upstream aligned timing for Earnings-22.

Earnings-21 lacks published aligned timestamps; that allocation is intentionally blocked
rather than estimating boundaries by word count or using model text as gold.
"""
import csv, io, hashlib, difflib
from common import Candidate, decode

REV='c05ab6fd8b4b627d123c922a22a39e993dd37635'
BASE=f'https://raw.githubusercontent.com/revdotcom/speech-datasets/{REV}'
MEDIA=f'https://media.githubusercontent.com/media/revdotcom/speech-datasets/{REV}'
FILES=('2020-03-0230487MTN-Ghana-2019-Annual-Results-Call','4423872','4481952')
SOURCE=dict(id='rev-earnings',name='Earnings-22/21 Rev verbatim',url='https://github.com/revdotcom/speech-datasets',revision=REV,licence='CC BY-SA 4.0 text only; audio rights unclear',licenceUrl=f'{BASE}/earnings22/LICENSE.md',redistributable=False,released='2022',attribution='Rev, Earnings-22 and Earnings-21 human verbatim transcripts.',referenceProduction='Professional Rev verbatim transcription; case, prepunctuation and punctuation are original token columns; aligned timestamps never supply text.')

def _rows(ctx, corpus, name, aligned=False):
    suffix=f'transcripts/{"force_aligned_nlp_references" if aligned else "nlp_references"}/{name}{".aligned" if aligned else ""}.nlp'
    path=ctx.http_file(f'{BASE}/{corpus}/{suffix}',name=f'{corpus}-{name}{"-aligned" if aligned else ""}.nlp')
    data=path.read_bytes().decode('utf-8-sig')
    return list(csv.DictReader(io.StringIO(data),delimiter='|')),suffix,hashlib.sha256(path.read_bytes()).hexdigest()

def _token(r): return (r.get('prepunctuation') or '')+r['token']+(r.get('punctuation') or '')

def _one(ctx, name):
    rows,path,sha=_rows(ctx,'earnings22',name)
    times,aligned_path,aligned_sha=_rows(ctx,'earnings22',name,True)
    matcher=difflib.SequenceMatcher(None,[r['token'].casefold() for r in rows],
                                     [r['token'].casefold() for r in times],autojunk=False)
    anchors={}
    for block in matcher.get_matching_blocks():
        for i in range(block.size):
            original=block.a+i; aligned=times[block.b+i]
            if aligned['ts'] and aligned['endTs']:
                anchors[original]=(float(aligned['ts']),float(aligned['endTs']))
    valid=[(i,*v) for i,v in sorted(anchors.items())]
    if not valid: raise ValueError(f'{name}: no aligned anchors')
    # Interior 4-minute span; require that transcript alignment is dense. At a short
    # pause near each approximate boundary, both adjacent human tokens have times.
    duration=max(x[2] for x in valid)
    def boundary(approx):
        opts=[]
        for j in range(1,len(valid)):
            ix,s,e=valid[j]; prev=valid[j-1]
            if ix!=prev[0]+1 or abs(s-approx)>45 or s-prev[2]<.15: continue
            if rows[ix-1]['punctuation'] not in ('.','?','!',';',','): continue
            opts.append((abs(s-approx),-min(s-prev[2],2),ix,s))
        if not opts: raise ValueError(f'{name}: no aligned pause near {approx}')
        return min(opts)[2:]
    windows=[]
    for fraction in (.08,.13,.20,.27,.34,.42,.49,.56):
        try:
            first,start=boundary(max(80,duration*fraction))
            last,end=boundary(start+240)
            if not 180<=end-start<=310: continue
            if any("<inaudible>" in _token(r) for r in rows[first:last]): continue
            density=sum(i in anchors for i in range(first,last))/(last-first)
            windows.append((density,first,last,start,end))
        except ValueError: continue
    if not windows: raise ValueError(f'{name}: no 3–5 min aligned window')
    density,first,last,start,end=max(windows)
    if density<.72: raise ValueError(f'{name}: sparse aligned text {density:.2%}')
    sub=rows[first:last]
    text=' '.join(map(_token,sub))
    return Candidate(key=f'{name}-{first}-{last}',language='en',duration=end-start,reference=text,referenceType='formatted',group=name,conditions=('spontaneous','earnings-call','accented'),stratum=name,origin=dict(repo='revdotcom/speech-datasets',revision=REV,path=f'{corpus_path("earnings22",path)}',referenceSha256=sha,alignedPath=f'{corpus_path("earnings22",aligned_path)}',alignedSha256=aligned_sha,audioUrl=f'{MEDIA}/earnings22/media/{name}.mp3',start=start,end=end,firstToken=first,lastTokenExclusive=last,channel='mean'),extra={})

def corpus_path(corpus,path): return corpus+'/'+path



def extract(ctx,cand):
    path=ctx.http_file(cand.origin['audioUrl'],name=f"rev-{cand.group}.mp3")
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    if cand.origin.get('sourceSha256') and digest!=cand.origin['sourceSha256']: raise ValueError('audio SHA mismatch')
    cand.origin['sourceSha256']=digest
    samples,rate=decode(path,cand.origin['start'],cand.origin['end'])
    return samples,rate,'mean'
