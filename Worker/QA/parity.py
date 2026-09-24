#!/usr/bin/env python3
"""Developer-only parity qualification; NEVER packaged, installed, or used to build Vella.
Uses the explicitly selected existing reference interpreter, worker and Vella scorers.
"""
import argparse, hashlib, json, os, pathlib, select, subprocess, sys, time, uuid


def idle(status):
    # Missing/unreadable status is not permission to contend with the user's app.
    if json.loads(status.read_text()).get('phase') != 'idle':
        raise RuntimeError('Vella is not idle; stop qualification')


def request(child, model, audio, status):
    idle(status)
    identifier = str(uuid.uuid4())
    child.stdin.write((json.dumps(dict(id=identifier, model=str(model), audio=str(audio)))+'\n').encode())
    child.stdin.flush()
    deadline = time.monotonic()+125
    data = bytearray()
    while not data.endswith(b'\n'):
        idle(status)
        if time.monotonic() >= deadline: raise TimeoutError('Worker deadline')
        if select.select([child.stdout], [], [], .25)[0]:
            block = os.read(child.stdout.fileno(), 65536)
            if not block: raise RuntimeError(f'Worker EOF, code={child.poll()}')
            data.extend(block)
            if len(data) > 2*1024*1024: raise RuntimeError('Unbounded worker output')
    result = json.loads(data)
    if result.get('id') != identifier: raise RuntimeError('Response identifier mismatch')
    return result


def clip_request(child, model, paths, status):
    parts = [request(child, model, path, status) for path in paths]
    if len(parts) == 1: return parts[0]
    failure = next((part for part in parts if 'error' in part), None)
    if failure: return dict(failure, segments=parts)
    metrics = dict(parts[0]['metrics'])
    for key in ('audioSeconds', 'inferenceSeconds', 'cleanupSeconds', 'requestSeconds', 'loadSeconds'):
        metrics[key] = sum(part['metrics'][key] for part in parts)
    for key in metrics:
        if key.endswith('Bytes'): metrics[key] = max(part['metrics'].get(key, 0) for part in parts)
    metrics['modelLoaded'] = any(part['metrics']['modelLoaded'] for part in parts)
    return dict(id=parts[0]['id'], text=' '.join(part['text'] for part in parts if part['text']), metrics=metrics, segments=parts)


def run(command, model, clips, args, output):
    identity = dict(model=str(model), configSHA256=hashlib.sha256((model/'config.json').read_bytes()).hexdigest(), command=command,
                    executableSHA256=hashlib.sha256(pathlib.Path(command[-1]).read_bytes()).hexdigest(), repeats=args.repeats,
                    manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest())
    previous = json.loads(output.read_text()) if args.resume and output.exists() else {}
    if previous.get('identity', identity) != identity: raise RuntimeError('Resume identity changed')
    rows = previous.get('clips', [])
    if [row['id'] for row in rows] != [clip['id'] for clip, _ in clips[:len(rows)]]: raise RuntimeError('Resume clip order changed')
    if any('error' in r for row in rows for r in row['responses']): raise RuntimeError('Cannot resume a completed error response')
    if previous.get('complete'): return dict(previous, identity=identity)
    idle(args.status)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
    child = subprocess.Popen(['sandbox-exec', '-p', '(version 1)(allow default)(deny network*)', *command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    warmups = previous.get('resumeWarmups', [])
    try:
        cold = clip_request(child, model, clips[0][1], args.status)
        if 'error' in cold: return dict(cold=cold, clips=[], qualified=False)
        if previous.get('cold'):
            warmups.append(cold); cold = previous['cold']
        for clip, audio in clips[len(rows):]:
            responses = [clip_request(child, model, audio, args.status) for _ in range(args.repeats)]
            rows.append(dict(id=clip['id'], reference=clip['reference'], responses=responses))
            output.write_text(json.dumps(dict(identity=identity, cold=cold, resumeWarmups=warmups, clips=rows, complete=False), indent=2)+'\n')
            if any('error' in r for r in responses): break
        child.stdin.close()
        child.wait(timeout=10)
        if child.returncode: raise RuntimeError(f'Nonzero EOF exit {child.returncode}')
        return dict(identity=identity, cold=cold, resumeWarmups=warmups, clips=rows, complete=len(rows)==144, exitCode=child.returncode)
    finally:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--swift-worker', type=pathlib.Path, required=True)
    p.add_argument('--python', type=pathlib.Path, required=True)
    p.add_argument('--resources', type=pathlib.Path, required=True)
    p.add_argument('--manifest', type=pathlib.Path, required=True)
    p.add_argument('--model', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--resume', action='store_true', help='Resume task-owned partial rows; never mix changed model/worker identities')
    p.add_argument('--repeats', type=int, default=2, choices=range(1,21))
    p.add_argument('--status', type=pathlib.Path, default=pathlib.Path.home()/'Library/Application Support/Vella/dictation-status.json')
    args = p.parse_args()
    for name in ('swift_worker', 'python', 'resources', 'manifest', 'model', 'output', 'status'):
        setattr(args, name, getattr(args,name).absolute() if name == "python" else getattr(args,name).resolve())
    idle(args.status)
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    if manifest['id'] != 'english-formatted-20m-v1' or len(manifest['clips']) != 144: raise ValueError('Wrong corpus')
    sys.path.insert(0, str(args.resources))
    from benchmark_worker import errors, fingerprint
    from formatting_metrics import score, aggregate
    import wave
    clips=[]
    for clip in manifest['clips']:
        source = args.manifest.parent/clip['file']
        if hashlib.sha256(source.read_bytes()).hexdigest() != clip['sha256']: raise ValueError('Audio hash mismatch')
        target=args.output/(clip['id']+'.wav')
        if not target.exists(): subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16', str(source), str(target)], check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        with wave.open(str(target), 'rb') as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000,1,2): raise ValueError('Unexpected converted reference format')
        paths = []
        with wave.open(str(target), 'rb') as wav:
            pcm = wav.readframes(wav.getnframes())
        if len(pcm) <= 960000:
            paths = [target]
        else:
            for index, start in enumerate(range(0, len(pcm), 960000)):
                segment = args.output/(clip['id']+f'.segment{index}.wav')
                with wave.open(str(segment), 'wb') as out:
                    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000); out.writeframes(pcm[start:start+960000])
                paths.append(segment)
        clips.append((clip,paths))

    commands={'python':[str(args.python), '-B', str(args.resources/'inference_worker.py')], 'swift':[str(args.swift_worker)]}
    runs={}
    for name, command in commands.items():
        runs[name] = run(command, args.model, clips, args, args.output/(name+'.json'))
        (args.output/(name+'.json')).write_text(json.dumps(runs[name],indent=2)+'\n')
    summary=dict(model=str(args.model), modelFingerprint=fingerprint(args.model), manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(), repeats=args.repeats, segmentation="Protocol-safe nonoverlap 30 s; only 7021-79730-0003 (32.88 s) splits; concatenate nonempty texts with spaces",
                 scorerSHA256=hashlib.sha256((args.resources/'formatting_metrics.py').read_bytes()).hexdigest(), lexicalWorkerSHA256=hashlib.sha256((args.resources/'benchmark_worker.py').read_bytes()).hexdigest(), models={})
    import statistics
    for name, run_data in runs.items():
        rows=run_data['clips']
        if not run_data.get('complete') or any('error' in r for row in rows for r in row['responses']):
            summary['models'][name] = dict(qualified=False, reason='Incomplete/error run'); continue
        pairs=[errors(row['reference'],row['responses'][0]['text']) for row in rows]
        formatted=aggregate([score(row['reference'],row['responses'][0]['text']) for row in rows])
        metrics=[r['metrics'] for row in rows for r in row['responses']]
        summary['models'][name]=dict(wer=sum(x[0] for x in pairs)/sum(x[1] for x in pairs), cer=formatted['formattedCharacterErrorRate'], formatting=formatted,
            cold=run_data['cold']['metrics'], warmSpeed=manifest['audioSeconds']/sum(statistics.median(r['metrics']['inferenceSeconds'] for r in row['responses']) for row in rows),
            peakFootprint=max(m.get('processPeakFootprintBytes',0) for m in metrics), peakMLX=max(m['peakMLXBytes'] for m in metrics),
            repeatDifferences=[row['id'] for row in rows if len({r['text'] for r in row['responses']})>1])
    if all('wer' in x for x in summary['models'].values()):
        differences=[dict(id=a['id'], python=a['responses'][0]['text'], swift=b['responses'][0]['text']) for a,b in zip(runs['python']['clips'],runs['swift']['clips']) if a['responses'][0]['text']!=b['responses'][0]['text']]
        summary['differences']=differences
        summary['exactParity']=not differences
        summary['nonRegression']=all(summary['models']['swift'][metric]<=summary['models']['python'][metric] for metric in ('wer','cer'))
    (args.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary))

if __name__ == '__main__':
    try: main()
    except RuntimeError as error:
        if str(error) == 'Vella is not idle; stop qualification':
            print(str(error), file=sys.stderr); raise SystemExit(75)
        raise
