#!/usr/bin/env python3
"""Accelerated direct production Session benchmark; never live/IPC latency.

Run timing and memory as separate processes. No downloads, app changes, or model
selection. --gpu-slot-released is an explicit orchestration assertion, not a lock.
"""
import argparse
import base64
import hashlib
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import platform
import resource
import signal
import statistics
import struct
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True
from benchmark_worker import errors, words, fingerprint, validate_model, atomic_json
import formatting_metrics as formatting
import streaming_worker as worker

ROOT = Path(__file__).resolve().parent
STATUS = Path.home() / 'Library/Application Support/Vella/dictation-status.json'
RUNTIME = Path.home() / 'Library/Application Support/Vella/Runtimes/mlx-audio-0.5.1-mlx-0.32.2-8d5faf2609fb-python-3.14/bin/python'
MEMORY_PROTOCOL = ('MLX allocation high-water mark reset after warmup, measured across transcription; '
                   'includes held model allocations, excludes untracked Python/native memory. Not total process or system RAM.')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def idle(path=STATUS):
    # Fail closed: missing/malformed status cannot establish a safe inference slot.
    phase = json.loads(Path(path).read_text())['phase']
    if phase not in ('idle', 'success', 'failed'):
        raise RuntimeError('Vella is busy or status is unknown: ' + str(phase))


class Guardian:
    def __enter__(self):
        idle()
        self.stop = threading.Event()
        def watch():
            while not self.stop.wait(.2):
                try:
                    idle()
                except Exception:
                    os.kill(os.getpid(), signal.SIGTERM)
                    return
        self.thread = threading.Thread(target=watch, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join(timeout=1)


class Transcript:
    """Exactly StreamingBackend's committed + partial joining, no cleanup."""
    def __init__(self):
        self.committed = ''
        self.text = ''
        self.incomplete = False
        self.prefix_ok = True
        self.events = []

    def accept(self, event, frames):
        if event.get('frames') != frames or event.get('error'):
            raise ValueError('Audio acknowledgement mismatch or worker error')
        next_text = event.get('committed', '').strip()
        if next_text:
            self.committed += (' ' if self.committed else '') + next_text
        text = ' '.join(x for x in (self.committed, event.get('partial', '')) if x)
        compatible = text.startswith(self.text)
        self.prefix_ok &= compatible
        self.text = text
        self.incomplete |= bool(event.get('incomplete'))
        self.events.append(dict(event, prefixAppendOnly=compatible))


def requests(samples):
    # Freeze exact float32 transport payloads before timing. Includes short tail.
    result = []
    for start in range(0, len(samples), worker.MAX_FRAMES):
        packet = samples[start:start + worker.MAX_FRAMES]
        raw = struct.pack('<' + 'f' * len(packet), *packet)
        result.append((len(packet), dict(id=str(uuid.uuid4()), op='audio',
                                        pcm=base64.b64encode(raw).decode('ascii'))))
    return result


def replay(native, packets, synchronize=lambda: None, check=lambda: None):
    # A fresh Session clears endpoint/preroll/accounting while retaining weights.
    check()
    native.reset()
    session = worker.Session()
    session.native = native
    transcript = Transcript()
    elapsed = 0.0
    frames = 0
    for size, request in packets + [(0, dict(id=str(uuid.uuid4()), op='finish'))]:
        check()
        synchronize()
        start = time.perf_counter()
        event = session.handle(request)
        synchronize()
        elapsed += time.perf_counter() - start
        frames += size
        transcript.accept(event, frames)
    if not event.get('done') or event.get('partial') or session.frames != frames:
        raise ValueError('Finish did not drain exact audio')
    return dict(transcript=transcript.text, seconds=elapsed, frames=frames,
                incomplete=transcript.incomplete, prefixAppendOnly=transcript.prefix_ok,
                events=transcript.events)


def frozen_suite(suite):
    manifest_path = Path(suite) / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    policy = json.loads((ROOT / 'benchmark-policy.json').read_text())
    normalizer = hashlib.sha256(inspect.getsource(words).encode()).hexdigest()
    if (manifest['id'] != policy['suiteID'] or sha(manifest_path) != policy['suiteHash']
            or formatting.SCORER_SHA256 != policy['scorerSHA256']
            or normalizer != policy['lexicalNormalizerSHA256'] or len(manifest['clips']) != 144):
        raise ValueError('Frozen corpus/scorer/normalizer mismatch')
    for clip in manifest['clips']:
        if sha(Path(suite) / clip['file']) != clip['sha256']:
            raise ValueError('Benchmark audio checksum mismatch: ' + clip['id'])
    return manifest, policy


def attach_memory(timing, memory):
    """Return a copy; never replace accuracy, timing, repeats or raw clip evidence."""
    if (timing.get('measurementKind') != 'timing' or memory.get('measurementKind') != 'memory'
            or not timing.get('complete') or not memory.get('complete')
            or timing.get('repeats') != 2 or memory.get('repeats') != 1):
        raise ValueError('Requires completed two-pass timing and separate one-pass memory')
    for key in ('recognitionMode', 'streamingQualified', 'modelID', 'modelFingerprint',
                'suiteID', 'suiteHash', 'audioHashes', 'machine', 'machineMemoryBytes',
                'os', 'mlxAudioVersion', 'mlxVersion', 'parameters',
                'streamingWorkerSHA256', 'driverSHA256', 'benchmarkWorkerSHA256'):
        if key not in timing or timing[key] != memory.get(key):
            raise ValueError('Memory provenance mismatch: ' + key)
    result = dict(timing)
    result['runtimePeakMLXBytes'] = memory['runtimePeakMLXBytes']
    result['memoryProtocol'] = memory['memoryProtocol']
    result['memoryMeasurement'] = {key: memory[key] for key in (
        'measuredAt', 'repeats', 'measurementKind', 'runtimePeakMLXBytes',
        'peakMLXBytes', 'peakProcessBytes', 'memoryProtocol', 'modelFingerprint',
        'suiteHash', 'streamingWorkerSHA256', 'driverSHA256', 'parameters',
        'mlxAudioVersion', 'mlxVersion', 'machine')}
    result['memoryMeasurement']['resultSHA256'] = hashlib.sha256(
        json.dumps(memory, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return result


def benchmark(args):
    manifest, policy = frozen_suite(args.suite)
    entry = next(x for x in json.loads(Path(args.catalog).read_text()) if x['id'] == args.model_id)
    validate_model(args.model, entry)
    identity = fingerprint(args.model)
    worker_hash, driver_hash = sha(worker.__file__), sha(__file__)
    worker.offline()  # No network fallback; pinned local data only.
    import mlx.core as mx
    from mlx_audio.audio_io import read
    files = []
    for clip in manifest['clips']:
        samples, rate = read(str(Path(args.suite) / clip['file']))
        if rate != 16000 or samples.ndim != 1:
            raise ValueError('Corpus must be original mono 16 kHz; no resampling allowed')
        files.append((clip, len(samples), requests(samples.tolist())))
    if args.limit:
        files = files[:args.limit]
    parameters = dict(packetFrames=worker.MAX_FRAMES, sampleRate=16000, sampleFormat='Float32LE',
                      gateFrames=worker.BLOCK, preRollBlocks=worker.PRE_ROLL,
                      trailingSilenceBlocks=worker.TRAILING, energyRMS=worker.ENERGY,
                      endpoint='production Session.endpoint', finish='production Session.handle(finish)',
                      decode='production native incremental greedy', perClipReset=True,
                      timingScope='accelerated direct Session.handle + MLX synchronization; excludes model load, IPC, packet encoding, scoring and inter-clip reset')
    parameters['architecture'] = entry['architecture']
    parameters['native'] = dict(worker.BENCHMARK_PARAMETERS[entry['architecture']])
    outcomes = []
    with Guardian():
        native = worker.Native(worker.model_path(str(Path(args.model).resolve())))
        try:
            replay(native, files[0][2], mx.synchronize, idle)  # untimed warmup
            mx.synchronize()
            loading_peak = mx.get_peak_memory()
            mx.reset_peak_memory()
            for clip, frames, packets in files:
                runs = [replay(native, packets, mx.synchronize, idle) for _ in range(args.repeats)]
                distance, count = errors(clip.get('lexicalReference', clip['reference']), runs[0]['transcript'])
                outcome = dict(id=clip['id'], reference=clip['reference'], lexicalReference=clip['lexicalReference'],
                               transcript=runs[0]['transcript'], allTranscripts=[r['transcript'] for r in runs],
                               duration=frames/16000, frames=frames, audioSHA256=clip['sha256'],
                               seconds=statistics.median(r['seconds'] for r in runs), allSeconds=[r['seconds'] for r in runs],
                               errors=distance, referenceWords=count,
                               repeatTextIdentical=len({r['transcript'] for r in runs}) == 1,
                               incomplete=any(r['incomplete'] for r in runs),
                               prefixAppendOnly=all(r['prefixAppendOnly'] for r in runs),
                               runs=runs, formatting=formatting.score(clip['reference'], runs[0]['transcript']))
                outcomes.append(outcome)
                atomic_json(str(args.output) + '.partial.json', dict(complete=False, clips=outcomes))
                print(json.dumps(dict(event='progress', clip=clip['id'], completed=len(outcomes), total=len(files))), flush=True)
            runtime_peak = mx.get_peak_memory()
        finally:
            native.close()
    if sha(worker.__file__) != worker_hash or sha(__file__) != driver_hash:
        raise ValueError('Worker or driver changed during run')
    frozen_suite(args.suite)
    def sysctl(name):
        return subprocess.run(['/usr/sbin/sysctl', '-n', name], capture_output=True, text=True, timeout=5, check=True).stdout.strip()
    duration = sum(x['duration'] for x in outcomes)
    seconds = sum(x['seconds'] for x in outcomes)
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    result = dict(schemaVersion=1, recognitionMode='streaming', streamingQualified=True,
                  complete=len(outcomes) == 144, measurementKind=args.measurement,
                  streamingWorkerSHA256=worker_hash, driverSHA256=driver_hash,
                  benchmarkWorkerSHA256=sha(ROOT / 'benchmark_worker.py'),
                  modelID=args.model_id, modelFingerprint=identity, modelName=entry['name'], quantization=entry['quantization'],
                  suiteID=manifest['id'], suiteHash=policy['suiteHash'],
                  audioHashes={c['id']: c['sha256'] for c in manifest['clips']},
                  machine=sysctl('machdep.cpu.brand_string') or platform.machine(),
                  machineMemoryBytes=int(sysctl('hw.memsize')), os=platform.platform(),
                  mlxAudioVersion=importlib.metadata.version('mlx-audio'), mlxVersion=importlib.metadata.version('mlx'),
                  parameters=parameters, processorSource=entry.get('processorSource'),
                  measuredAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  repeats=args.repeats, audioSeconds=duration, transcriptionSeconds=seconds,
                  realtimeFactor=duration/seconds, wordErrorRate=sum(x['errors'] for x in outcomes)/sum(x['referenceWords'] for x in outcomes),
                  peakProcessBytes=rss if sys.platform == 'darwin' else rss*1024,
                  peakMLXBytes=max(loading_peak, runtime_peak), runtimePeakMLXBytes=runtime_peak,
                  memoryProtocol=MEMORY_PROTOCOL, clips=outcomes,
                  formatting=formatting.aggregate([x['formatting'] for x in outcomes]),
                  note=('Accelerated native streaming compute throughput, NOT end-to-end live latency or strict batch timing equivalence. '
                        'Each packet includes MLX synchronization; inter-clip reset, load and IPC are excluded. '
                        'Batch generate timings include their own per-clip encoder setup. '
                        'Process RSS includes benchmark preencoded corpus buffers and event evidence; MLX allocation memory does not. '
                        + manifest.get('description', '')))
    result['formatting']['lexicalNormalizerSHA256'] = policy['lexicalNormalizerSHA256']
    result['prefixAppendOnly'] = all(x['prefixAppendOnly'] for x in outcomes)
    result['incompleteClipCount'] = sum(x['incomplete'] for x in outcomes)
    result['repeatDifferenceClipIDs'] = [x['id'] for x in outcomes if not x['repeatTextIdentical']]
    result['streamingQualified'] = (result['complete'] and result['prefixAppendOnly']
                                    and result['incompleteClipCount'] == 0)
    atomic_json(args.output, result)
    print(json.dumps(dict(event='result', path=str(args.output))), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', default=str(ROOT / 'streaming-models.json'))
    parser.add_argument('--model-id', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--suite', default=str(ROOT / 'Benchmarks/english-formatted-20m-v1'))
    parser.add_argument('--output', required=True)
    parser.add_argument('--measurement', choices=['timing', 'memory'], default='timing')
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--limit', type=int, default=0, help='Pilot only; never a complete suite')
    parser.add_argument('--deadline', type=int, default=3600)
    parser.add_argument('--gpu-slot-released', action='store_true', required=True)
    args = parser.parse_args()
    if args.repeats != (2 if args.measurement == 'timing' else 1):
        parser.error('Timing requires two passes; separate memory process requires one')
    if not 0 <= args.limit <= 144 or not 1 <= args.deadline <= 14400:
        parser.error('Invalid limit/deadline')
    if Path(sys.executable).absolute() != RUNTIME:
        parser.error('Use the exact pinned Vella runtime: ' + str(RUNTIME))
    def stop(*_):
        raise RuntimeError('Benchmark stopped: deadline, termination, or busy Vella')
    signal.signal(signal.SIGALRM, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.alarm(args.deadline)
    try:
        benchmark(args)
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps(dict(event='error', message=str(error))), flush=True)
        sys.exit(1)
