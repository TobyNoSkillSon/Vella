#!/usr/bin/env python3
"""Real Main/Session/Watchdog; MLX import removed, fake native only. No GPU."""
import base64,json,os,select,signal,struct,subprocess,sys,tempfile,time,uuid
from pathlib import Path
binary=sys.argv[1]
id=str(uuid.UUID(int=1))
def launch():return subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def send(p,obj):p.stdin.write(json.dumps(obj).encode()+b'\n');p.stdin.flush()
def receive(p,timeout=5):
    assert select.select([p.stdout],[],[],timeout)[0], 'reply timeout'
    line=p.stdout.readline();assert line and line.isascii(),repr(line)
    return json.loads(line)
def retired(p):
    assert p.wait(timeout=5)==0
    try:os.kill(p.pid,0)
    except ProcessLookupError:return
    raise AssertionError('PID still exists')
with tempfile.TemporaryDirectory(prefix='vella-cpu-wire-') as directory:
    folder=Path(directory);(folder/'config.json').write_text('{"model_type":"nemotron_asr"}');(folder/'x.safetensors').touch()
    def start(p):send(p,dict(id=id,op='start',model=directory));assert receive(p)==dict(id=id,frames=0)
    p=launch();start(p)
    audio=base64.b64encode(struct.pack('<320f',*([.1]*320))).decode()
    send(p,dict(id=id,op='audio',pcm=audio));assert receive(p)['partial']=='naïve 😀'
    send(p,dict(id=id,op='finish'));reply=receive(p);assert reply['done'] and reply['frames']==320
    retired(p) # stdin intentionally remains open: Finish must retire independently.
    for raw in [b'{}\n',b'!\n',b'x'*10001,b'{"id":"x"}\n']:
        p=launch();p.stdin.write(raw);p.stdin.flush();r=receive(p);assert r['error']=='Invalid local streaming request.';retired(p)
    p=launch();p.stdin.write(b'{}');p.stdin.close();assert receive(p)['error']=='Invalid local streaming request.';retired(p)
    p=launch();p.stdin.close();retired(p);assert p.stdout.read()==b''
    p=launch();start(p);send(p,dict(id=id,op='audio',pcm='AAAA'))
    assert receive(p)['error']=='Invalid local streaming request.';retired(p);assert p.stdout.read()==b''
    p=launch();start(p)
    slow=base64.b64encode(struct.pack('<320f',*([16.]*320))).decode()
    send(p,dict(id=id,op='audio',pcm=slow));time.sleep(.25);p.send_signal(signal.SIGTERM)
    assert receive(p)==dict(id=id,error='Local streaming transcription failed.');retired(p)
    print('PASS real control-flow CPU wire: framing, ASCII, Finish/open-stdin exit, EOF, sticky error, SIGTERM during operation',flush=True)
    if '--idle-timeout' in sys.argv:
        p=launch();t=time.monotonic()
        assert receive(p,125)==dict(id=None,error='Local streaming transcription failed.');retired(p)
        elapsed=time.monotonic()-t;assert 119<=elapsed<=125,elapsed
        print('PASS real idle watchdog: %.3fs, one error and verified process exit'%elapsed,flush=True)
