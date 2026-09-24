#!/usr/bin/env python3
"""Developer-only differential invalid-request/EOF check; no model load."""
import argparse, json, os, pathlib, subprocess, uuid
p=argparse.ArgumentParser()
p.add_argument('--python',required=True);p.add_argument('--resources',type=pathlib.Path,required=True)
p.add_argument('--worker',required=True);p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args()
status=pathlib.Path.home()/'Library/Application Support/Vella/dictation-status.json'
if json.loads(status.read_text()).get('phase')!='idle': raise SystemExit('Vella not idle')
i=str(uuid.uuid4())
requests=[None,[],{},dict(id=i),dict(id=i,model='relative',audio='relative'),dict(id='bad',model='/',audio='/'),dict(id=i,model='/does/not/exist',audio='/does/not/exist'),dict(id=i,model='/',audio='/',extra=True),dict(id=0,model='/',audio='/'),dict(id=i,model='/',audio='/',extra=float('nan')),dict(id=i,model=float('inf'),audio='/')]
wire=b''.join(json.dumps(x).encode()+b'\n' for x in requests)+b'not json\n'+b'x'*20000+b'\n{}\n'
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
results={}
for name, command in [('python',[a.python,'-B',str(a.resources/'inference_worker.py')]),('swift',[a.worker])]:
    if json.loads(status.read_text()).get('phase')!='idle': raise SystemExit('Vella not idle')
    r=subprocess.run(['sandbox-exec','-p','(version 1)(allow default)(deny network*)',*command],input=wire,capture_output=True,env=env,timeout=20)
    rows=[json.loads(line) for line in r.stdout.splitlines()]
    assert r.returncode==0 and len(rows)==len(requests)+3 and r.stderr==b'',(name,r.returncode,len(rows),r.stderr)
    results[name]=rows
assert results['python']==results['swift'],results
summary=dict(cases=len(results['swift']),exactJSONParity=True,EOFExit=0,stdoutOnlyJSON=True,stderrEmpty=True)
a.output.write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
