#!/usr/bin/env python3
"""Developer-only CLI contract checks, using the frozen public calibration sample."""
import argparse,json,pathlib,subprocess,tempfile,shutil,math,time
p=argparse.ArgumentParser();p.add_argument('--worker',required=True);p.add_argument('--model',required=True);p.add_argument('--sample',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
status=pathlib.Path.home()/'Library/Application Support/Vella/dictation-status.json'
def run(sample):
 while json.loads(status.read_text()).get('phase')!='idle':time.sleep(.25)
 c=subprocess.run(['sandbox-exec','-p','(version 1)(allow default)(deny network*)',a.worker,'calibrate','--model',a.model,'--sample',str(sample)],capture_output=True,text=True,timeout=125)
 assert c.stderr=='',c.stderr
 return c,[json.loads(x) for x in c.stdout.splitlines()]
results=[]
for sample in [a.sample.resolve(),(a.sample/'speech.wav').resolve()]:
 c,events=run(sample);assert c.returncode==0,events
 assert [x['event'] for x in events]==['progress']*4+['result']
 r=events[-1]['result'];assert len(r['warmSeconds'])==2 and r['audioSeconds']==7.04
 assert r['parameters']==dict(chunk_duration=30.0,stream=False),r['parameters']
 assert r['sampleSHA256']=='e36af54bcd25cbbb9c1adba8ff28bc7a4001a91f6bfdbc3360df9efd395bafa2'
 assert abs(r['speed']-r['audioSeconds']/(sum(r['warmSeconds'])/2))<1e-9
 assert all(math.isfinite(v) and v>0 for v in [r['loadSeconds'],r['firstRequestSeconds'],*r['warmSeconds']])
 results.append(events)
with tempfile.TemporaryDirectory() as temp:
 dest=pathlib.Path(temp)/'Calibration';shutil.copytree(a.sample,dest)
 (dest/'text.txt').write_text('tampered public fixture')
 c,events=run(dest);assert c.returncode==1 and events[-1]==dict(event='error',message='Calibration sample identity mismatch'),events
 results.append(events)
a.output.write_text(json.dumps(dict(passed=True,runs=results),indent=2)+'\n')
print('Calibration: folder + WAV contracts, timings/median, SHA rejection and process exit passed')
