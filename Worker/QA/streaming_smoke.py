#!/usr/bin/env python3
"""At most five short public clips: protocol/transcript checks, no scoring/timing."""
import argparse,base64,hashlib,json,os,select,subprocess,sys,time,uuid
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
RUNTIME=Path.home()/'Library/Application Support/Vella/Runtimes/mlx-audio-0.5.1-mlx-0.32.2-8d5faf2609fb-python-3.14/bin/python'
STATUS=Path.home()/'Library/Application Support/Vella/dictation-status.json'
from mlx_audio.audio_io import read

def idle():
    if json.loads(STATUS.read_text()).get('phase')!='idle':raise RuntimeError('Vella not idle; stop owned smoke helper')

def run(command,model,packets):
    idle();p=subprocess.Popen(['sandbox-exec','-p','(version 1)(allow default)(deny network*)']+command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
    buffer=b'';events=[];text='';committed='';frames=0
    def call(request):
        nonlocal buffer
        idle();p.stdin.write(json.dumps(request).encode()+b'\n');p.stdin.flush();deadline=time.monotonic()+125
        while b'\n' not in buffer:
            idle()
            if time.monotonic()>deadline:raise TimeoutError('request deadline')
            if select.select([p.stdout],[],[],.1)[0]:
                data=os.read(p.stdout.fileno(),65536)
                if not data:raise RuntimeError('unexpected worker exit')
                buffer+=data
                if len(buffer)>65536:raise RuntimeError('oversized response')
        line,buffer=buffer.split(b'\n',1);reply=json.loads(line)
        assert reply.get('id')==request['id'] and 'error' not in reply,reply
        events.append(reply);return reply
    try:
        assert call(dict(id=str(uuid.UUID(int=0)),op='start',model=str(model)))['frames']==0
        for count,request in packets+[(0,dict(id=str(uuid.UUID(int=len(packets)+1)),op='finish'))]:
            reply=call(request);frames+=count;assert reply['frames']==frames
            delta=reply.get('committed','')
            if delta:committed+=' '*(bool(committed))+delta
            updated=' '.join(x for x in (committed,reply.get('partial','')) if x)
            assert updated.startswith(text),'earlier prefix revised';text=updated
        assert reply.get('done') and not reply.get('partial')
        p.stdin.close();assert p.wait(timeout=10)==0
        return dict(events=events,text=text,frames=frames,exitCode=0)
    finally:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--clips',type=int,default=3,choices=range(1,6));a=parser.parse_args()
    suite=ROOT/'Resources/Benchmarks/english-formatted-20m-v1';manifest=json.loads((suite/'manifest.json').read_text())
    clips=[c for c in manifest['clips'] if c['duration']<=6][:a.clips]
    a.output.mkdir(parents=True,exist_ok=True);summary=dict(mode='correctness smoke only; no scoring or timing',model=str(a.model),complete=False,clips=[])
    for clip in clips:
        audio=suite/clip['file'];assert hashlib.sha256(audio.read_bytes()).hexdigest()==clip['sha256']
        samples,rate=read(str(audio));assert rate==16000 and samples.ndim==1
        packets=[(len(samples[i:i+1600]),dict(id=str(uuid.UUID(int=i//1600+1)),op='audio',pcm=base64.b64encode(samples[i:i+1600].astype('<f4').tobytes()).decode())) for i in range(0,len(samples),1600)]
        pair=dict(id=clip['id'])
        for name,command in [('python',[str(RUNTIME),'-B',str(ROOT/'Resources/streaming_worker.py')]),('swift',[str(ROOT/'Worker/.build/release/VellaStreamingWorker')])]:pair[name]=run(command,a.model,packets)
        pair.update(eventsEqual=pair['python']['events']==pair['swift']['events'],textEqual=pair['python']['text']==pair['swift']['text'])
        (a.output/(clip['id']+'.json')).write_text(json.dumps(pair,ensure_ascii=False,indent=2))
        summary['clips'].append(dict(id=clip['id'],eventsEqual=pair['eventsEqual'],textEqual=pair['textEqual']))
        print(clip['id'],summary['clips'][-1],flush=True)
    summary['complete']=True
    summary['transcriptsMatch']=all(c['textEqual'] for c in summary['clips'])
    summary['eventsMatch']=all(c['eventsEqual'] for c in summary['clips'])
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
    if not summary['transcriptsMatch']:raise SystemExit('Transcript mismatch in correctness smoke')
if __name__=='__main__':main()
