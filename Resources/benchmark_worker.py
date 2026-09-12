#!/usr/bin/env python3
"""Vella benchmark worker. Isolated process; never uses or stops the dictation server."""
import fnmatch, threading
import argparse, hashlib, importlib.metadata, inspect, json, os, pathlib, platform, re, resource, statistics, subprocess, sys, time

def emit(event, **data):
    print(json.dumps(dict(event=event, **data)), flush=True)

def words(text):
    text = text.lower().replace("’", "'")
    return [token.strip("'") for token in re.sub(r"[^\w\s']|_", " ", text).split() if token.strip("'")]

def errors(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    previous = list(range(len(hyp) + 1))
    for i, a in enumerate(ref, 1):
        current = [i]
        for j, b in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j-1] + (a != b)))
        previous = current
    return previous[-1], len(ref)

def atomic_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n'); temporary.replace(path)

def fingerprint(folder):
    h = hashlib.sha256()
    files = sorted(pathlib.Path(folder).glob('*.safetensors')) + [pathlib.Path(folder)/'config.json']
    if not files or not files[-1].exists(): raise ValueError('Incomplete model folder')
    for file in files:
        h.update(file.name.encode())
        with file.open('rb') as stream:
            for block in iter(lambda: stream.read(8*1024*1024), b''): h.update(block)
    return h.hexdigest()

def validate_model(folder, entry):
    folder = pathlib.Path(folder)
    config = json.loads((folder/'config.json').read_text())
    architecture = config.get('model_type')
    if architecture is None and config.get('target') == 'nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel':
        architecture = 'parakeet'
    if architecture != entry['architecture']: raise ValueError('Model architecture does not match recommendation')
    # Admit only local built-in model/tokenizer implementations, even when an upstream
    # post-load hook enables remote-code support. Download recipes never fetch Python.
    for name in ('config.json', 'tokenizer_config.json'):
        file = folder/name
        if file.exists() and json.loads(file.read_text()).get('auto_map'):
            raise ValueError('Custom remote-code mappings are not supported')
    if list(folder.rglob('*.py')): raise ValueError('Model directory contains executable repository code')
    if architecture == 'sensevoice' and not (folder/'am.mvn').is_file():
        raise ValueError('SenseVoice normalization file am.mvn is required')
    quant = config.get('quantization') or config.get('quantization_config') or {}
    if entry['quantization'] in ('4-bit', '8-bit'):
        if quant.get('bits') != int(entry['quantization'].split('-')[0]): raise ValueError('Quantization does not match recommendation')
    elif quant.get('bits') is not None:
        raise ValueError('Expected unquantized weights')
    if not list(folder.glob('*.safetensors')): raise ValueError('Model weights are missing')

def download(args, entry):
    os.environ.setdefault('HF_HUB_DISABLE_XET', '1')
    os.environ['HF_HUB_DISABLE_PROGRESS_BARS'] = '1'
    from huggingface_hub import HfApi, snapshot_download
    from huggingface_hub._local_folder import get_local_download_paths
    destination = pathlib.Path(args.models_dir)/entry['id']
    patterns = ['*.json', '*.safetensors', '*.tiktoken', '*.txt', '*.model', '*.mvn', 'README.md', 'LICENSE*']
    sources = [(entry['repository'], entry['revision'], patterns)]
    if processor := entry.get('processorSource'):
        sources.append((processor['repository'], processor['revision'], processor['files']))
    emit('progress', message='Checking pinned Hugging Face files…')
    sizes = {}; transfers = {}
    for repo, revision, allowed in sources:
        info = HfApi().model_info(repo, revision=revision, files_metadata=True, timeout=20)
        for file in info.siblings:
            if any(fnmatch.fnmatch(file.rfilename, pattern) for pattern in allowed):
                if file.size is None: raise ValueError('Hub did not supply a file size')
                sizes[file.rfilename] = file.size
                etag = file.lfs.sha256 if file.lfs else file.blob_id
                if not etag: raise ValueError('Hub did not supply a content identity')
                paths = get_local_download_paths(destination, file.rfilename)
                transfers[file.rfilename] = (etag, paths)
    total = sum(sizes.values())
    stop = threading.Event()
    def report():
        while not stop.is_set():
            completed = 0
            for name, size in sizes.items():
                etag, paths = transfers[name]
                # Count only this pinned content, never another revision's cached partial.
                try:
                    metadata = paths.metadata_path.read_text().splitlines()
                    if len(metadata) >= 2 and metadata[1] == etag and paths.file_path.stat().st_size == size:
                        completed += size; continue
                except (FileNotFoundError, OSError): pass
                try: completed += min(paths.incomplete_path(etag).stat().st_size, size)
                except (FileNotFoundError, OSError): pass
            emit('progress', message='Downloading from Hugging Face…', completed=min(completed, total * .99), total=total)
            stop.wait(.25)
    monitor = threading.Thread(target=report, daemon=True); monitor.start()
    try:
        for repo, revision, allowed in sources:
            snapshot_download(repo, revision=revision, local_dir=destination,
                allow_patterns=allowed, etag_timeout=20, max_workers=4)
    finally:
        stop.set(); monitor.join(timeout=2)
    emit('progress', message='Verifying downloaded model…', completed=total * .99, total=total)
    for name, size in sizes.items():
        file = destination/name
        if file.stat().st_size != size: raise ValueError('Downloaded file size mismatch')
        etag, _ = transfers[name]
        digest = hashlib.sha256() if len(etag) == 64 else hashlib.sha1()
        if len(etag) == 40: digest.update(f'blob {size}\0'.encode())
        elif len(etag) != 64: raise ValueError('Unsupported Hub content hash')
        with file.open('rb') as stream:
            for block in iter(lambda: stream.read(8*1024*1024), b''): digest.update(block)
        if digest.hexdigest() != etag: raise ValueError(f'Downloaded content checksum mismatch: {name}')
    validate_model(destination, entry)
    emit('installed', modelID=entry['id'], path=str(destination), revision=entry['revision'])

def benchmark(args, entry):
    import mlx.core as mx
    from mlx_audio.audio_io import read as audio_read
    from mlx_audio.stt.utils import load_model
    manifest_path = pathlib.Path(args.suite)/'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    files = []
    for clip in manifest['clips']:
        path = pathlib.Path(args.suite)/clip['file']
        if hashlib.sha256(path.read_bytes()).hexdigest() != clip['sha256']: raise ValueError('Benchmark audio checksum mismatch')
        samples, rate = audio_read(str(path))
        files.append((clip, path, len(samples)/rate))
    emit('progress', message='Verifying model and loading it in an isolated process…')
    if entry: validate_model(args.model, entry)
    identity = fingerprint(args.model)
    model = load_model(args.model)
    kwargs = dict(verbose=False, max_tokens=1024, chunk_duration=30.0, stream=False)
    signature = inspect.signature(model.generate)
    kwargs = {k:v for k,v in kwargs.items() if k in signature.parameters}
    def transcribe(path):
        result = model.generate(str(path), **kwargs)
        if hasattr(result, '__next__'): return ''.join(getattr(x, 'text', str(x)) for x in result)
        return result.text
    emit('progress', message='Warming model; this pass is not timed…')
    transcribe(files[0][1]); mx.synchronize()
    loading_peak = mx.get_peak_memory()
    mx.reset_peak_memory()
    outcomes=[]
    for index, (clip, path, duration) in enumerate(files):
        timings=[]; transcripts=[]
        for repeat in range(args.repeats):
            emit('progress', message=f"Clip {index+1}/{len(files)} · pass {repeat+1}/{args.repeats}", completed=index*args.repeats+repeat, total=len(files)*args.repeats)
            mx.synchronize(); start=time.perf_counter()
            text=transcribe(path); mx.synchronize()
            timings.append(time.perf_counter()-start); transcripts.append(text)
        distance, count=errors(clip.get('lexicalReference', clip['reference']), transcripts[0])
        outcomes.append(dict(id=clip['id'], reference=clip['reference'], transcript=transcripts[0],
            duration=duration, seconds=statistics.median(timings), allSeconds=timings,
            errors=distance, referenceWords=count, repeatTextIdentical=len(set(transcripts))==1))
        if manifest.get('formattedReferences'):
            from formatting_metrics import score
            outcomes[-1]['lexicalReference'] = clip.get('lexicalReference', clip['reference'])
            outcomes[-1]['formatting'] = score(clip['reference'], transcripts[0])
    seconds=sum(x['seconds'] for x in outcomes); duration=sum(x['duration'] for x in outcomes)
    def sysctl(name):
        return subprocess.run(['/usr/sbin/sysctl','-n',name],capture_output=True,text=True,timeout=5).stdout.strip()
    rss=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    result=dict(schemaVersion=1, modelID=args.model_id, modelFingerprint=identity,
        modelName=entry['name'] if entry else args.model_id, quantization=entry['quantization'] if entry else 'Imported',
        suiteID=manifest['id'], suiteHash=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        machine=sysctl('machdep.cpu.brand_string') or platform.machine(),
        machineMemoryBytes=int(sysctl('hw.memsize') or 0), os=platform.platform(),
        mlxAudioVersion=importlib.metadata.version('mlx-audio'), mlxVersion=importlib.metadata.version('mlx'),
        parameters=kwargs, processorSource=entry.get('processorSource') if entry else None, measuredAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
        repeats=args.repeats, audioSeconds=duration, transcriptionSeconds=seconds,
        realtimeFactor=duration/seconds, wordErrorRate=sum(x['errors'] for x in outcomes)/sum(x['referenceWords'] for x in outcomes),
        peakProcessBytes=rss if sys.platform=='darwin' else rss*1024,
        peakMLXBytes=max(loading_peak, mx.get_peak_memory()),
        runtimePeakMLXBytes=mx.get_peak_memory(),
        memoryProtocol='MLX allocation high-water mark reset after warmup, measured across transcription; includes held model allocations, excludes untracked Python/native memory. Not total process or system RAM.',
        clips=outcomes, note='Warm isolated-process measurement. Other apps may affect speed. ' + manifest.get('description', ''))
    if manifest.get('formattedReferences'):
        from formatting_metrics import aggregate
        result['formatting'] = aggregate([x['formatting'] for x in outcomes])
        result['formatting']['lexicalNormalizerSHA256'] = hashlib.sha256(inspect.getsource(words).encode()).hexdigest()
    atomic_json(args.output,result)
    emit('result', path=args.output, result=result)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action', choices=['download','benchmark'])
    parser.add_argument('--catalog', required=True); parser.add_argument('--model-id', required=True)
    parser.add_argument('--model'); parser.add_argument('--models-dir'); parser.add_argument('--suite', default=str(pathlib.Path(__file__).parent/'Benchmarks/english-formatted-20m-v1')); parser.add_argument('--output')
    parser.add_argument('--repeats', type=int, default=2)
    args=parser.parse_args()
    if not 1 <= args.repeats <= 20: raise ValueError('repeats must be between 1 and 20')
    catalog=json.loads(pathlib.Path(args.catalog).read_text())
    entry=next((x for x in catalog if x['id']==args.model_id),None)
    if args.action=='download':
        if not entry or not args.models_dir: raise ValueError('Only curated models can be downloaded')
        download(args,entry)
    else:
        if not all([args.model,args.suite,args.output]): raise ValueError('Missing benchmark arguments')
        benchmark(args,entry)

if __name__=='__main__':
    try: main()
    except Exception as e:
        emit('error', message=str(e)); sys.exit(1)
