#!/usr/bin/env python3
"""CPU differential test of Swift and actual Python Session, using identical fakes."""
import base64, importlib.util, json, os, random, struct, subprocess, sys, tempfile, uuid
from pathlib import Path
sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('reference', root/'Resources/streaming_worker.py')
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
class Fake:
    drain = ref.Native.drain
    def __init__(self, path): self.reset()
    def reset(self): self.text = ''; self.serial = 0
    def push(self, samples, final=False):
        if any(samples): self.serial += 1; self.text += f' w{self.serial}'
    def close(self): pass
with tempfile.TemporaryDirectory(prefix='vella-stream-fixture-') as folder:
    p = Path(folder); (p/'config.json').write_text('{"model_type":"nemotron_asr"}'); (p/'x.safetensors').touch()
    counts = []
    for seed in range(8):
        rng = random.Random(seed)
        # Dense sequence forces repeated 2048-byte word drains without endpoints;
        # silence checks endpoints; arbitrary framing must not affect gate blocks.
        samples = [0.] * 9000 + [0.2] * 320000 + [0.] * 18000 + [0.1] * 4799
        requests = [dict(id=str(uuid.UUID(int=0)),op='start',model=folder)]
        offset=0
        while offset < len(samples):
            n = rng.randint(1,1600)
            packet=samples[offset:offset+n];offset+=len(packet)
            requests.append(dict(id=str(uuid.UUID(int=len(requests))),op='audio',pcm=base64.b64encode(struct.pack('<'+'f'*len(packet),*packet)).decode()))
        requests.append(dict(id=str(uuid.UUID(int=len(requests))),op='finish'))
        session=ref.Session(factory=Fake)
        expected=[session.handle(x) for x in requests]
        proc=subprocess.run([sys.argv[1]],input=''.join(json.dumps(x)+'\n' for x in requests),text=True,capture_output=True,timeout=30,check=True)
        actual=[json.loads(x) for x in proc.stdout.splitlines()]
        assert actual==expected, f'event mismatch seed {seed}'
        counts.append(len(actual))
    print('PASS Swift/Python exact synthetic Session events:',counts,'total',sum(counts))
