#!/usr/bin/env python3
"""Small tensor parity probe, no model weights; public corpus only."""
import dataclasses,hashlib,json,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'Resources'))
import streaming_worker as worker
from streaming_benchmark_worker import requests
from streaming_parity import idle
from mlx_audio.audio_io import read
import numpy as np
import mlx.core as mx
from mlx_audio.stt.models.nemotron_asr.audio import StreamingLogMelSpectrogram
from mlx_audio.stt.models.nemotron_asr.attention import RelPositionalEncoding
from mlx_audio.stt.models.nemotron_asr.config import PreprocessArgs
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
model=Path.home()/'Library/Application Support/Vella/Models/nemotron-3.5-asr-streaming-0.6b-bf16'
config=json.loads((model/'config.json').read_text())
class Capture:
    text=''
    def __init__(self):self.blocks=[];self.finals=0
    def push(self,samples,final=False):
        if samples:self.blocks.append(np.asarray(samples,dtype='<f4'))
        if final:self.finals+=1
    def drain(self,final=False):return ''
    def reset(self):pass
capture=Capture();session=worker.Session();session.native=capture
samples,rate=read(str(ROOT/'Resources/Benchmarks/english-formatted-20m-v1/4077-13754-0002.flac'));assert rate==16000
for _,packet in requests(samples.tolist()):session.handle(packet)
session.handle(dict(id='00000000-0000-0000-0000-000000000001',op='finish'));assert capture.finals==1
np.concatenate(capture.blocks).tofile(out/'gated.f32')
(out/'lengths.json').write_text(json.dumps([len(x) for x in capture.blocks]))
(out/'gate-ledger.json').write_text(json.dumps(dict(blocks=len(capture.blocks),samples=sum(map(len,capture.blocks)),endpoints=capture.finals,blockSHA256=[hashlib.sha256(x.tobytes()).hexdigest() for x in capture.blocks]),indent=2))
fields={f.name for f in dataclasses.fields(PreprocessArgs)}
args=PreprocessArgs(**{k:v for k,v in config['preprocessor'].items() if k in fields})
worker.offline()
idle();frontend=StreamingLogMelSpectrogram(args);mels=[]
for block in capture.blocks:
    idle();mel=frontend.push(mx.array(block));mx.eval(mel);mels.append(mel)
mels.append(frontend.flush());mx.save(str(out/'python-mel.npy'),mx.concatenate(mels,axis=1))
idle();pe=RelPositionalEncoding(config['encoder']['d_model']);mx.save(str(out/'python-position.npy'),pe._pe)
idle();child=subprocess.Popen(['sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(ROOT/'Worker/.build/release/VellaStreamingDiagnostics'),'--dump-front',str(model/'config.json'),str(out/'gated.f32'),str(out/'lengths.json'),str(out)])
try:
    deadline=time.monotonic()+120
    while child.poll() is None:
        idle()
        if time.monotonic()>deadline:raise TimeoutError('diagnostic child deadline')
        time.sleep(.1)
    if child.returncode:raise RuntimeError('diagnostic child failed')
finally:
    if child.poll() is None:
        child.terminate()
        try:child.wait(timeout=3)
        except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
summary={}
for key,a,b in [('mel','python-mel.npy','swift-mel.npy'),('positionCPU','python-position.npy','swift-position-cpu.npy'),('positionMLX','python-position.npy','swift-position-mlx.npy')]:
    x,y=np.load(out/a),np.load(out/b);assert x.shape==y.shape
    summary[key]=dict(shape=list(x.shape),dtype=str(x.dtype),different=int(np.count_nonzero(x!=y)),maxAbs=float(np.max(np.abs(x-y))))
    if 'position' in key:
        c=x.shape[1]//2;u,v=x[:,c-59:c+60],y[:,c-59:c+60]
        summary[key]['streamWindowDifferent']=int(np.count_nonzero(u!=v));summary[key]['streamWindowMaxAbs']=float(np.max(np.abs(u-v)))
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
