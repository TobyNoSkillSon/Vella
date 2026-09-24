#!/usr/bin/env python3
"""Public-fixture, offline Python stage oracle; no model/installed-runtime writes."""
import argparse, json, pathlib, sys
p=argparse.ArgumentParser();p.add_argument('--model',type=pathlib.Path,required=True);p.add_argument('--audio',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--resources',type=pathlib.Path,required=True)
a=p.parse_args();sys.path.insert(0,str(a.resources));from inference_worker import offline
offline()
import mlx.core as mx
from mlx_audio.stt.utils import load_model,load_audio
from mlx_audio.stt.models.parakeet.audio import log_mel_spectrogram
m=load_model(a.model)
x=load_audio(a.audio,16000,dtype=mx.bfloat16)
mel=log_mel_spectrogram(x,m.preprocessor_config);encoder,lengths=m.encoder(mel);mx.eval(mel,encoder,lengths)
arrays=dict(mel=mel,encoder=encoder,lengths=lengths,positional=m.encoder.pos_enc._pe)
t=encoder.shape[1];mid=m.encoder.pos_enc._pe.shape[1]//2
arrays["used_positional"]=m.encoder.pos_enc._pe[:,mid-t+1:mid+t].astype(encoder.dtype)
from mlx_audio.dsp import STR_TO_WINDOW_FN,hanning,stft,mel_filters
cfg=m.preprocessor_config
z=x
if cfg.pad_to>0 and z.shape[-1]<cfg.pad_to:z=mx.pad(z,((0,cfg.pad_to-z.shape[-1]),),constant_values=cfg.pad_value)
if cfg.preemph>0:z=mx.concatenate([z[:1],z[1:]-cfg.preemph*z[:-1]])
w=STR_TO_WINDOW_FN.get(cfg.window,hanning)(cfg.win_length)
if w.shape[0]<cfg.n_fft:
 left=(cfg.n_fft-w.shape[0])//2;w=mx.concatenate([mx.zeros(left,dtype=w.dtype),w,mx.zeros(cfg.n_fft-cfg.win_length-left,dtype=w.dtype)])
spectrum=stft(z,cfg.n_fft,cfg.hop_length,cfg.n_fft,w,pad_mode='constant')
absolute=mx.abs(spectrum);power=mx.square(absolute).astype(x.dtype)
filters=mel_filters(cfg.sample_rate,cfg.n_fft,cfg.features,norm='slaney',mel_scale='slaney')
linear=filters.astype(power.dtype)@power.T
logged=mx.log(linear+mx.array(cfg.log_zero_guard_value,dtype=linear.dtype))
mean=mx.mean(logged,axis=1,keepdims=True);variance=mx.sum((logged-mean)**2,axis=1,keepdims=True)/max(logged.shape[1]-1,1);std=mx.sqrt(variance)
arrays.update(waveform=x,preemphasis=z,window=w,stft_abs=absolute,power=power,filters=filters,mel_linear=linear,mel_log=logged,mel_mean=mean,mel_variance=variance,mel_std=std)
arrays.update(difference=logged-mean,deviations=(logged-mean)**2,variance_sum=mx.sum((logged-mean)**2,axis=1,keepdims=True),denominator=mx.array(max(logged.shape[1]-1,1),dtype=logged.dtype))
original=m._compiled_tdt_step
@mx.compile
def probe(feature,token,hidden,cell):
    embedded=m.decoder.prediction['embed'](token)
    embedded=mx.where(mx.expand_dims(token==m.blank_id,-1),mx.zeros_like(embedded),embedded)
    out,(h,c)=m.decoder.prediction['dec_rnn'](embedded,(hidden,cell))
    joint=m.joint(feature,out.astype(feature.dtype))
    return joint
steps=[]
def wrapped(feature,token,hidden,cell):
    pred,duration,h,c=original(feature,token,hidden,cell)
    logits=probe(feature,token,hidden,cell)
    mx.eval(pred,duration,h,c,logits)
    prefix=f'step_{len(steps):04d}'
    for k,v in [('feature',feature),('token',token),('hidden',hidden),('cell',cell),('logits',logits)]:arrays[prefix+'_'+k]=v
    pred_i=int(pred);d_i=int(duration)
    same=pred_i==int(mx.argmax(logits[0,0,:,:m.blank_id+1])) and d_i==int(mx.argmax(logits[0,0,:,m.blank_id+1:]))
    steps.append(dict(token=pred_i,duration=d_i,probeDecisionMatches=same))
    return pred,duration,h,c
m._compiled_tdt_step=wrapped
result=m.generate(x,chunk_duration=30,stream=False)
a.output.mkdir(parents=True,exist_ok=True)
mx.save_safetensors(str(a.output/'stages.safetensors'),arrays)
(a.output/'trace.json').write_text(json.dumps(dict(text=result.text,steps=steps),indent=2)+'\n')
print(json.dumps(dict(text=result.text,steps=len(steps),arrays=len(arrays))))
