"""Four distinct Rev16 podcast episodes, human verbatim text with time-only aligned cuts."""
import csv, hashlib, io
from common import Candidate, decode
REV='c05ab6fd8b4b627d123c922a22a39e993dd37635'
HF='sanchit-gandhi/rev16_csv';HFREV='acad9372c439d3d538f846e1c4df9bb9a2730ba1'
BASE=f'https://raw.githubusercontent.com/revdotcom/speech-datasets/{REV}/rev16/verbatim_transcripts/nlp_references'
# Fixed by separate time-only Parakeet alignment against verbatim Rev tokens. At each
# boundary, 3+ reference/hypothesis words agree on both sides around an audible pause.
CUTS={
 '9':(2058,3165,635.44,930.0,.964),
 '10':(1923,2882,658.48,959.12,.959),
 '17':(2113,3140,654.24,957.76,.911),
 '21':(2366,3550,626.32,924.88,.856),
}
SOURCE=dict(id='rev16',name='Rev16 verbatim podcast episodes',url='https://github.com/revdotcom/speech-datasets/tree/'+REV+'/rev16',revision=f'Rev text {REV}; podcast mirror {HF}@{HFREV}',licence='CC BY-SA 4.0 text only; podcast audio rights unclear',licenceUrl=f'https://raw.githubusercontent.com/revdotcom/speech-datasets/{REV}/rev16/LICENSE.md',redistributable=False,released='2023',attribution='Radford et al. (2023), Rev transcriptionists; underlying podcast creators retain media rights.',referenceProduction='Professional human verbatim Rev transcription; case, punctuation and fillers reconstructed solely from nlp token columns. Parakeet used only for cut times, never text.')
def extract(ctx,cand):
    path=ctx.hf_file(HF,cand.origin['audioPath'],HFREV)
    sha=hashlib.sha256(path.read_bytes()).hexdigest()
    if cand.origin.get('sourceSha256') and sha!=cand.origin['sourceSha256']:raise ValueError('podcast audio SHA mismatch')
    cand.origin['sourceSha256']=sha
    a,rate=decode(path,cand.origin['start'],cand.origin['end'])
    return a,rate,'mean'
