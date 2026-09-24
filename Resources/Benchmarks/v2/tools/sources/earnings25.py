"""Q4-2025 disjoint industry segments; entire source segments, no mid-word cuts."""
import hashlib, re
import pyarrow.parquet as pq
from common import Candidate,decode
REPO='florencejiang/earnings25';REV='b4864bf8f0cd1e3b153e502d45bb29cd46993f21'
IDS=('442581471_2446.68_2788.68','443205335_2396.68_2720.05','444138651_1342.92_1750.20','443751007_1197.56_1604.04')
SOURCE=dict(id='earnings25',name='Earnings25 segmented Q4 2025',url='https://huggingface.co/datasets/florencejiang/earnings25',revision=REV,licence='CC BY 4.0 transcripts/metadata; recording redistribution unclear',licenceUrl='https://arxiv.org/html/2607.23813v1',redistributable=False,released='2026-06',attribution='Florence Jiang et al., Earnings25 (2026), Zenodo DOI 10.5281/zenodo.18762167.',referenceProduction='Existing earnings-call transcripts paired to corporate audio with CTC forced alignment. Original transcriber and human review unreported; NOT Formatting gold.')
def _path(shard): return f'segmented/test-{shard:05d}-of-00008.parquet'
def candidates(ctx):
    out=[]
    for shard in range(8):
        path=_path(shard)
        with ctx.hf_open(REPO,path,REV) as f:
            p=pq.ParquetFile(f)
            for rg in range(p.metadata.num_row_groups):
                rows=p.read_row_group(rg,columns=['id','text','company','industry','release_date','duration_s','segments']).to_pylist()
                for ix,r in enumerate(rows):
                    if r['id'] not in IDS: continue
                    if r['release_date']<'2025-10' or not 180<=r['duration_s']<=420: raise ValueError('not Q4 or 3-7 min')
                    if not r['text'].strip(): raise ValueError('empty reference')
                    # Dataset's presegmented file boundary is source forced-aligned;
                    # do not derive a fake midpoint from the transcript.
                    out.append(Candidate(key=r['id'],language='en',duration=r['duration_s'],reference=re.sub(r'\[ph\]', '', r['text']),referenceType='formatted',group=r['id'].split('_')[0],conditions=('earnings-call','long-form','domain:finance'),stratum=r['industry'],origin=dict(repo=REPO,revision=REV,path=path,rowGroup=rg,row=ix,upstreamId=r['id'],channel='mean',sourceBoundary='published presegmented 3–7-minute item'),extra=dict(company=r['company'],industry=r['industry'],releaseDate=r['release_date'])))
    if set(x.key for x in out)!=set(IDS): raise ValueError('selected IDs missing from pinned segmented shards')
    return sorted(out,key=lambda c:c.key)
def select(ctx,cands,target_seconds): return cands

def prepare(ctx,chosen):
    groups={}
    for c in chosen:
        target=ctx.cache/'earnings25'/f'{c.key}.bin'
        if not target.exists(): groups.setdefault((c.origin['path'],c.origin['rowGroup']),[]).append(c)
    for (path,rg),subset in sorted(groups.items()):
        with ctx.hf_open(REPO,path,REV) as f:
            rows=pq.ParquetFile(f).read_row_group(rg,columns=['id','audio']).to_pylist()
        for c in subset:
            row=rows[c.origin['row']]
            if row['id']!=c.key: raise ValueError('row ID mismatch')
            data=row['audio']['bytes']; dest=ctx.cache/'earnings25'/f'{c.key}.bin'
            dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)

def extract(ctx,cand):
    path=ctx.cache/'earnings25'/f'{cand.key}.bin'
    if not path.exists(): prepare(ctx,[cand])
    data=path.read_bytes(); digest=hashlib.sha256(data).hexdigest()
    if cand.origin.get('sourceSha256') and cand.origin['sourceSha256']!=digest: raise ValueError('source SHA mismatch')
    cand.origin['sourceSha256']=digest
    a,rate=decode(data);return a,rate,'mean'
