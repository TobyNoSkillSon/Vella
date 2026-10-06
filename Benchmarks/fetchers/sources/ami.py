"""Official Edinburgh AMI ES2004a manual XML paired with raw Array1-01 channel.

Words group into turns per speaker when successive lexical words are <=0.7 s apart.
Windows begin/end at full-turn boundaries with no crossing turn; references serialize
all speakers' words by word start (then end and speaker). Punctuation is attached to
its preceding speaker word. Isolated turn clips have no competing speaker turn.
"""
import zipfile,xml.etree.ElementTree as ET
from common import Candidate,decode
AUDIO='https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Array1-01.wav'
ANN='https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip'
ANN_SHA='b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d'
AUDIO_SHA='6936edac5d0904fc5c4ab175546c5cc5366601fdc1b1e5183a6ea2c10f05d150'
SOURCE=dict(id='ami',name='AMI ES2004a official manual annotations',url='https://groups.inf.ed.ac.uk/ami/download/',
 revision=f'manual-v1.6.2 SHA256:{ANN_SHA}; ES2004a.Array1-01.wav SHA256:{AUDIO_SHA}',
 licence='CC BY 4.0',licenceUrl='https://groups.inf.ed.ac.uk/ami/download/',redistributable=True,released='2005; manual annotations v1.6.2 2017-04-10',
 attribution='AMI Corpus, University of Edinburgh; official AMI download, CC BY 4.0.',
 referenceProduction='AMI manually transcribed orthographic word XML with word timestamps, speaker and original punctuation.')

def _source(ctx):
    path=ctx.http_file(ANN,sha256=ANN_SHA,name='ami_public_manual_1.6.2.zip')
    words=[];turns=[]
    with zipfile.ZipFile(path) as z:
        for speaker in 'ABCD':
            root=ET.fromstring(z.read(f'words/ES2004a.{speaker}.words.xml'))
            raw=[]
            for el in root:
                if el.tag!='w':continue # non-speech vocal sounds, gaps and disfluency markup
                a=float(el.attrib['starttime']);b=float(el.attrib['endtime']); text=el.text or ''
                if el.attrib.get('punc')=='true':
                    if raw:raw[-1]['text']+=text
                    continue
                if not text:continue
                raw.append(dict(a=a,b=b,text=text,sp=speaker))
            chunk=[]
            for w in raw:
                if chunk and w['a']-chunk[-1]['b']>.7:
                    turns.append(dict(a=chunk[0]['a'],b=chunk[-1]['b'],sp=speaker,words=chunk));chunk=[]
                chunk.append(w)
            if chunk:turns.append(dict(a=chunk[0]['a'],b=chunk[-1]['b'],sp=speaker,words=chunk))
            words.extend(raw)
    return sorted(words,key=lambda w:(w['a'],w['b'],w['sp'])),sorted(turns,key=lambda t:(t['a'],t['b'],t['sp']))

def _make(words,a,b,kind,speaker=None):
    selected=[w for w in words if w['a']>=a-1e-6 and w['b']<=b+1e-6]
    if not selected:return None
    return Candidate(key=f'ES2004a-{kind}-{a:.2f}-{b:.2f}',language='en',duration=b-a,
      reference=' '.join(w['text'] for w in selected),referenceType='formatted',group='ES2004a',speaker=speaker,
      conditions=('meeting','far-field','overlap' if kind=='window' else 'isolated-turn'),stratum=kind,
      origin=dict(audioUrl=AUDIO,audioSha256=AUDIO_SHA,annotationUrl=ANN,annotationSha256=ANN_SHA,
                  annotationFiles=[f'words/ES2004a.{s}.words.xml' for s in 'ABCD'],channel='Array1-01',start=a,end=b),
      extra=dict(kind=kind,wordCount=len(selected)))

def extract(ctx,cand):
    o=cand.origin;path=ctx.http_file(o['audioUrl'],sha256=o['audioSha256'],name='ES2004a.Array1-01.wav')
    samples,rate=decode(path,o['start'],o['end'])
    return samples,rate,0
