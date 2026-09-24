#!/usr/bin/env python3
"""CPU-only numerical comparison of the public-fixture Parakeet stage probes."""
import json,pathlib,sys
import mlx.core as mx
import numpy as np
root=pathlib.Path(sys.argv[1]);results={}
with mx.stream(mx.cpu):
 for clip in ['5142-36377-0000','6930-75918-0000']:
  folder=root/clip
  a=mx.load(str(folder/'python/stages.safetensors'));b=mx.load(str(folder/'swift/stages.safetensors'))
  ta=json.loads((folder/'python/trace.json').read_text());tb=json.loads((folder/'swift/trace.json').read_text())
  def compare(key):
   x=np.asarray(a[key].astype(mx.float32));y=np.asarray(b[key].astype(mx.float32))
   if x.shape!=y.shape:return dict(shapePython=x.shape,shapeSwift=y.shape)
   d=np.abs(x-y)
   return dict(shape=x.shape,dtypePython=str(a[key].dtype),dtypeSwift=str(b[key].dtype),exact=bool(np.array_equal(x,y)),different=int(np.count_nonzero(d)),maxAbs=float(d.max()),meanAbs=float(d.mean()))
  first=next((i for i,(x,y) in enumerate(zip(ta['steps'],tb['steps'])) if (x['token'],x['duration'])!=(y['token'],y['duration'])),None)
  r=dict(pythonText=ta['text'],swiftText=tb['text'],steps=[len(ta['steps']),len(tb['steps'])],firstDecisionDifference=first,
         probeArgmaxMatches=[all(x['probeDecisionMatches'] for x in ta['steps']),all(x['probeDecisionMatches'] for x in tb['steps'])],
         stages={key:compare(key) for key in ['waveform','preemphasis','window','stft_abs','power','filters','mel_linear','mel_log','mel_mean','difference','deviations','variance_sum','denominator','mel_variance','mel_std','mel','positional','used_positional','encoder','lengths']})
  for i in sorted({0,first} - {None}):
   r['stages'][f'logits_{i}']=compare(f'step_{i:04d}_logits')
   r['stages'][f'hidden_{i}']=compare(f'step_{i:04d}_hidden')
  results[clip]=r
(root/'comparison.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
