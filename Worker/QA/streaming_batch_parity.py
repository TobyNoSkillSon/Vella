#!/usr/bin/env python3
"""Warm-weight parity via real Session implementations, like repository benchmark.
Production executable framing/retirement is qualified separately by streaming_parity.py.
"""
import base64, json, os, select, subprocess, sys, time, uuid, argparse, hashlib
from pathlib import Path
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Resources'))
if len(sys.argv)>1 and sys.argv[1]=='--reference-probe':
    import streaming_worker as worker
    import mlx.core as mx, resource, ctypes
    worker.offline()
    resident = None; path = None
    def factory(p):
        global resident,path
        if path != p:
            if resident is not None: resident.close()
            resident=worker.Native(p);path=p
        else: resident.reset()
        return resident
    session=worker.Session(factory=factory)
    try:
        for line in sys.stdin:
            reply=session.handle(json.loads(line));print(json.dumps(reply),flush=True)
            if json.loads(line).get('op') == 'start': mx.reset_peak_memory()
            if session.done:
                usage=(ctypes.c_uint64*64)()
                status=ctypes.CDLL(None).proc_pid_rusage(os.getpid(),4,ctypes.byref(usage))
                metrics=dict(peakMLXBytes=mx.get_peak_memory(),activeMLXBytes=mx.get_active_memory(),cacheMLXBytes=mx.get_cache_memory(),processPeakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
                if status==0:metrics.update(processRSSBytes=usage[8],processFootprintBytes=usage[9],processPeakFootprintBytes=usage[30])
                print(json.dumps(metrics),file=sys.stderr,flush=True)
                session.native=None;session.close();session=worker.Session(factory=factory)
    finally:
        if resident is not None: resident.close()
    raise SystemExit()
from streaming_parity import idle,RUNTIME
from streaming_benchmark_worker import Transcript,frozen_suite
from mlx_audio.audio_io import read
import formatting_metrics as formatting
from benchmark_worker import errors, words
class Peer:
    def __init__(self, command, diagnostics):
        idle();self.buffer=b'';self.diagnostics=open(diagnostics,'a')
        self.p=subprocess.Popen(['sandbox-exec','-p','(version 1)(allow default)(deny network*)']+command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.diagnostics,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
    def call(self, request):
        idle();self.p.stdin.write(json.dumps(request).encode()+b'\n');self.p.stdin.flush();deadline=time.monotonic()+125
        while b'\n' not in self.buffer:
            idle()
            if time.monotonic()>deadline:raise TimeoutError('request timeout')
            if select.select([self.p.stdout],[],[],.1)[0]:
                b=os.read(self.p.stdout.fileno(),65536)
                if not b:raise RuntimeError('unexpected EOF '+str(self.p.poll()))
                self.buffer+=b
                if len(self.buffer)>100000:raise RuntimeError('response size exceeded')
        line,self.buffer=self.buffer.split(b'\n',1); reply=json.loads(line)
        if reply.get('error') or reply.get('id')!=request['id']:raise RuntimeError(str(reply))
        return reply
    def close(self, success):
        try:
            if success:self.p.stdin.close();self.p.wait(timeout=10)
            else:self.p.terminate();self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=3)
        self.diagnostics.close()
        if success and self.p.returncode:raise RuntimeError('worker nonzero exit '+str(self.p.returncode))
def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--limit',type=int,default=144)
    p.add_argument('--paced',action='store_true');p.add_argument('--silence-gaps',action='store_true')
    p.add_argument('--resume',action='store_true');p.add_argument('--wait-for-idle',action='store_true')
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    if a.wait_for_idle and not a.resume:p.error('--wait-for-idle requires --resume')
    suite=ROOT/'Resources/Benchmarks/english-formatted-20m-v1';manifest,policy=frozen_suite(suite)
    packets=[]
    for clip in manifest['clips'][:a.limit]:
        samples,rate=read(str(suite/clip['file']));assert rate==16000 and samples.ndim==1
        if a.silence_gaps:
            import numpy as np
            samples=np.concatenate([np.zeros(6400,dtype='float32'),samples,np.zeros(19200,dtype='float32'),samples,np.zeros(16000,dtype='float32')])
        chunks=[(len(samples[i:i+1600]),dict(id=str(uuid.UUID(int=i//1600+1)),op='audio',pcm=base64.b64encode(samples[i:i+1600].astype('<f4').tobytes()).decode())) for i in range(0,len(samples),1600)]
        packets.append((clip,chunks))
    summary=dict(model=str(a.model),suite=manifest['id'],policy=policy,mode='retained weights / fresh production Sessions',paced=a.paced,silenceGaps=a.silence_gaps,complete=False)
    seals=dict(modelConfigSHA256=hashlib.sha256((a.model/'config.json').read_bytes()).hexdigest(),probeSHA256=hashlib.sha256((ROOT/'Worker/.build/release/VellaStreamingProbe').read_bytes()).hexdigest(),referenceSHA256=hashlib.sha256((ROOT/'Resources/streaming_worker.py').read_bytes()).hexdigest())
    if a.resume and (a.output/'summary.json').exists():
        old=json.loads((a.output/'summary.json').read_text())
        for key in ('model','suite','policy','paced','silenceGaps'):
            if old.get(key)!=summary[key]:raise RuntimeError('Resume input mismatch: '+key)
        for key,value in seals.items():
            if key in old and old[key]!=value:raise RuntimeError('Resume seal mismatch: '+key)
        if 'probeSHA256' not in old and list(a.output.glob('swift-*.json')):raise RuntimeError('Unsealed prior native results cannot be resumed')
    summary.update(seals)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
    # One loaded model at a time; never hold Python and Swift resident together.
    for name,command in [('python',[str(RUNTIME),'-B',str(Path(__file__).resolve()),'--reference-probe']),('swift',[str(ROOT/'Worker/.build/release/VellaStreamingProbe')])]:
        remaining=[]
        for clip,chunks in packets:
            record=a.output/(name+'-'+clip['id']+'.json')
            if a.resume and record.exists():
                saved=json.loads(record.read_text())
                if saved.get('frames')!=sum(n for n,_ in chunks) or not saved['events'][-1].get('done'):raise RuntimeError('Invalid checkpoint '+str(record))
            else:remaining.append((clip,chunks))
        if not remaining:continue
        peer=Peer(command,a.output/(name+'-metrics.jsonl'));success=False
        try:
            for clip,chunks in remaining:
                transcript=Transcript(); events=[];frames=0;t=time.monotonic()
                events.append(peer.call(dict(id=str(uuid.UUID(int=0)),op='start',model=str(a.model))))
                loaded=time.monotonic();clock=loaded
                for count,packet in chunks:
                    if a.paced:
                        clock+=count/16000
                        while time.monotonic()<clock:idle();time.sleep(min(.05,max(0,clock-time.monotonic())))
                    reply=peer.call(packet);frames+=count;transcript.accept(reply,frames);events.append(reply)
                reply=peer.call(dict(id=str(uuid.UUID(int=len(chunks)+1)),op='finish'));transcript.accept(reply,frames);events.append(reply)
                if not reply.get('done') or reply.get('partial'):raise RuntimeError('finish failed')
                result=dict(events=events,text=transcript.text,prefixAppendOnly=transcript.prefix_ok,frames=frames,loadSeconds=loaded-t,replaySeconds=time.monotonic()-loaded,formatting=formatting.score(clip['reference'],transcript.text))
                (a.output/(name+'-'+clip['id']+'.json')).write_text(json.dumps(result,indent=2,ensure_ascii=False))
                print(name,clip['id'],flush=True)
            success=True
        finally:peer.close(success)
    diffs=[]; metrics={}
    for name in ('python','swift'):
        records=[json.loads((a.output/(name+'-'+clip['id']+'.json')).read_text()) for clip,_ in packets]
        total=sum(len(words(clip['reference'])) for clip,_ in packets)
        edits=sum(errors(clip['reference'],r['text'])[0] for (clip,_),r in zip(packets,records))
        metrics[name]=dict(wer=edits/total,formatting=formatting.aggregate([r['formatting'] for r in records]),replaySeconds=sum(r['replaySeconds'] for r in records),allPrefixesImmutable=all(r['prefixAppendOnly'] for r in records))
    for clip,_ in packets:
        x,y=[json.loads((a.output/(name+'-'+clip['id']+'.json')).read_text()) for name in ('python','swift')]
        if x['events']!=y['events']:diffs.append(dict(id=clip['id'],textEqual=x['text']==y['text'],python=x['text'],swift=y['text'],eventIndices=[i for i,(u,v) in enumerate(zip(x['events'],y['events'])) if u!=v]))
    summary.update(complete=True,clips=len(packets),differences=diffs,metrics=metrics)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2));print('COMPLETE',len(packets),'event differences',len(diffs),flush=True)
if __name__=='__main__':
    while True:
        try:main();break
        except RuntimeError as error:
            if '--wait-for-idle' not in sys.argv or 'User Vella is not idle' not in str(error):raise
            print('PAUSED: owned child exited; waiting for user Vella idle',flush=True)
            while True:
                time.sleep(.25)
                try:idle();break
                except RuntimeError:continue
