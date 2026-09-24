#!/usr/bin/env python3
"""Developer-only production-JSONL parity; never a build/install dependency."""
import argparse, base64, hashlib, json, os, select, subprocess, sys, time, uuid
from pathlib import Path
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
STATUS = Path.home() / 'Library/Application Support/Vella/dictation-status.json'
RUNTIME = Path.home() / 'Library/Application Support/Vella/Runtimes/mlx-audio-0.5.1-mlx-0.32.2-8d5faf2609fb-python-3.14/bin/python'
sys.path.insert(0, str(ROOT / 'Resources'))
from streaming_benchmark_worker import Transcript, frozen_suite
from mlx_audio.audio_io import read as read_audio

def idle():
    if json.loads(STATUS.read_text()).get('phase') != 'idle':
        raise RuntimeError('User Vella is not idle; stopped owned inference')

def replay(command, model, packets, paced):
    idle()
    start = time.monotonic()
    process = subprocess.Popen(['sandbox-exec', '-p', '(version 1)(allow default)(deny network*)'] + command,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HF_HUB_OFFLINE='1'))
    events, pending = [], b''
    def request(value):
        nonlocal pending
        idle(); process.stdin.write(json.dumps(value).encode() + b'\n'); process.stdin.flush()
        deadline = time.monotonic() + 125
        while b'\n' not in pending:
            idle()
            if time.monotonic() > deadline: raise TimeoutError('Worker request exceeded deadline')
            if select.select([process.stdout], [], [], .1)[0]:
                data = os.read(process.stdout.fileno(), 65536)
                if not data: raise RuntimeError('Worker EOF, exit=' + str(process.poll()))
                pending += data
                if len(pending) > 100000: raise RuntimeError('Unbounded worker response')
        line, pending = pending.split(b'\n', 1)
        result = json.loads(line)
        if result.get('id') != value['id']: raise RuntimeError('ID mismatch')
        events.append(result)
        if 'error' in result: raise RuntimeError(json.dumps(result))
        return result
    try:
        request(dict(id=str(uuid.UUID(int=0)), op='start', model=str(model)))
        loaded = time.monotonic()
        transcript = Transcript(); frames = 0; clock = loaded
        for count, packet in packets:
            if paced:
                # Match microphone availability: packet arrives after its duration.
                clock += count / 16000
                while time.monotonic() < clock:
                    idle(); time.sleep(min(.05, max(0, clock - time.monotonic())))
            event = request(packet); frames += count; transcript.accept(event, frames)
        event = request(dict(id=str(uuid.UUID(int=len(packets) + 1)), op='finish'))
        transcript.accept(event, frames)
        if not event.get('done') or event.get('partial'): raise RuntimeError('Unfinished stream')
        process.stdin.close(); process.wait(timeout=10)
        if process.returncode: raise RuntimeError('Nonzero process exit: ' + str(process.returncode))
        return dict(events=events, text=transcript.text, prefixAppendOnly=transcript.prefix_ok,
                    frames=frames, loadSeconds=loaded-start, replaySeconds=time.monotonic()-loaded,
                    exitCode=process.returncode)
    except Exception as error:
        return dict(events=events, error=str(error))
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--native', type=Path, default=ROOT/'Worker/.build/release/VellaStreamingWorker')
    p.add_argument('--limit', type=int, default=144); p.add_argument('--paced', action='store_true')
    p.add_argument('--clip-id', help='One exact public manifest clip, for isolated repeat diagnostics')
    p.add_argument('--silence-gaps', action='store_true')
    p.add_argument('--gpu-slot-released', action='store_true', required=True)
    a = p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)
    suite = ROOT/'Resources/Benchmarks/english-formatted-20m-v1'
    manifest, policy = frozen_suite(suite)
    summary = dict(model=str(a.model), modelConfigSHA256=hashlib.sha256((a.model/'config.json').read_bytes()).hexdigest(),
                   suite=manifest['id'], policy=policy, paced=a.paced, silenceGaps=a.silence_gaps, clips=[])
    selected = [c for c in manifest['clips'] if c['id'] == a.clip_id] if a.clip_id else manifest['clips'][:a.limit]
    if not selected: p.error('No matching manifest clip')
    for clip in selected:
        samples, rate = read_audio(str(suite/clip['file'])); assert rate == 16000 and samples.ndim == 1
        if a.silence_gaps:
            import numpy as np
            # Intact clip, then 1.2s endpoint silence, then same intact clip.
            samples = np.concatenate([np.zeros(6400, dtype='float32'), samples, np.zeros(19200, dtype='float32'), samples, np.zeros(16000, dtype='float32')])
        packets = [(len(samples[i:i+1600]), dict(id=str(uuid.UUID(int=i//1600+1)), op='audio',
                   pcm=base64.b64encode(samples[i:i+1600].astype('<f4').tobytes()).decode())) for i in range(0,len(samples),1600)]
        pair = dict(id=clip['id'], reference=clip['reference'])
        for name, command in [('python',[str(RUNTIME),'-B',str(ROOT/'Resources/streaming_worker.py')]), ('swift',[str(a.native)])]:
            pair[name] = replay(command,a.model,packets,a.paced)
            if pair[name].get('error'): break
        failed = any(pair.get(n,{}).get('error') for n in ('python','swift')) or 'swift' not in pair
        pair['eventsEqual'] = not failed and pair['python']['events'] == pair['swift']['events']
        pair['textEqual'] = not failed and pair['python']['text'] == pair['swift']['text']
        (a.output/(clip['id']+'.json')).write_text(json.dumps(pair,ensure_ascii=False,indent=2))
        summary['clips'].append({k:v for k,v in pair.items() if k not in ('python','swift')})
        summary['complete'] = len(summary['clips']) == len(selected) and not failed
        (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
        print(clip['id'], 'ERROR' if failed else 'exact' if pair['eventsEqual'] else 'events differ; text='+str(pair['textEqual']), flush=True)
        if failed: raise SystemExit(json.dumps(pair.get('swift', pair['python']).get('error')))
if __name__ == '__main__': main()
