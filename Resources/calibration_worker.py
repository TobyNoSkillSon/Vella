#!/usr/bin/env python3
"""Short, offline speed calibration. One licensed sample; no user speech, HTTP, or weight downloads."""
import argparse
import hashlib
import importlib.metadata
import inspect
import json
import math
import os
import pathlib
import signal
import statistics
import time
import wave

SAMPLE_SHA256 = 'e36af54bcd25cbbb9c1adba8ff28bc7a4001a91f6bfdbc3360df9efd395bafa2'
TEXT_SHA256 = '5d1772325ea342a62f30872e6ce9fb4c109dc20aa997bd921e9c92385a997d7e'
MAX_SECONDS = 120


def emit(event, **value):
    print(json.dumps(dict(event=event, **value), allow_nan=False), flush=True)


def sample(folder):
    folder = pathlib.Path(folder)
    manifest = json.loads((folder / 'manifest.json').read_text())
    audio = folder / 'speech.wav'
    if (hashlib.sha256(audio.read_bytes()).hexdigest() != SAMPLE_SHA256
            or manifest['sha256'] != SAMPLE_SHA256
            or hashlib.sha256((folder / 'text.txt').read_bytes()).hexdigest() != TEXT_SHA256
            or manifest['textSHA256'] != TEXT_SHA256):
        raise ValueError('Calibration sample identity mismatch')
    with wave.open(str(audio)) as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 16000):
            raise ValueError('Unexpected calibration audio format')
        seconds = w.getnframes() / w.getframerate()
    if not 3 <= seconds <= 15 or abs(manifest['audioSeconds'] - seconds) > .0001:
        raise ValueError('Unexpected calibration duration')
    return audio, seconds


def validate_local(folder):
    # Reuse the benchmark's admission checks, never its corpus or accuracy scorer.
    from benchmark_worker import validate_model
    folder = pathlib.Path(folder).resolve(strict=True)
    config = json.loads((folder / 'config.json').read_text())
    architecture = config.get('model_type')
    if config.get('target') == 'nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel':
        architecture = architecture or 'parakeet'
    if architecture not in ('whisper', 'qwen3_asr', 'parakeet', 'sensevoice', 'granite_speech'):
        raise ValueError('Unsupported local architecture')
    quant = config.get('quantization') or config.get('quantization_config') or {}
    bits = quant.get('bits')
    if bits not in (None, 4, 8):
        raise ValueError('Unsupported quantization')
    validate_model(folder, dict(architecture=architecture, quantization=f'{bits}-bit' if bits else 'Unquantized'))
    return folder


def measure(model, audio, seconds, synchronize, clock=time.perf_counter):
    kwargs = dict(verbose=False, max_tokens=1024, chunk_duration=30.0, stream=False)
    signature = inspect.signature(model.generate)
    kwargs = {k: v for k, v in kwargs.items() if k in signature.parameters}

    def run():
        synchronize()
        start = clock()
        result = model.generate(str(audio), **kwargs)
        characters = 0
        def count_text(value):
            text = value.get('text', '') if isinstance(value, dict) else getattr(value, 'text', value if isinstance(value, str) else '')
            return len(text.strip()) if isinstance(text, str) else 0
        if hasattr(result, '__next__'):
            for item in result:
                characters += count_text(item)
        else:
            characters = count_text(result)
        synchronize()
        if characters < 10:
            raise ValueError('Calibration produced no usable speech text')
        elapsed = clock() - start
        if not math.isfinite(elapsed) or elapsed <= 0:
            raise ValueError('Invalid inference timing')
        return elapsed

    emit('progress', message='Calibrating: first request…')
    first = run()
    warm = []
    for repeat in range(2):
        emit('progress', message=f'Calibrating: warm pass {repeat + 1}/2…')
        warm.append(run())
    return dict(audioSeconds=seconds, firstRequestSeconds=first, warmSeconds=warm,
                speed=seconds / statistics.median(warm), parameters=kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--sample', required=True)
    args = parser.parse_args()
    # A hard process-local deadline also covers native inference that holds the GIL.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(MAX_SECONDS)
    for name in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE', 'HF_HUB_DISABLE_TELEMETRY'):
        os.environ[name] = '1'
    folder = validate_local(args.model)
    audio, seconds = sample(args.sample)
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    emit('progress', message='Calibrating: loading local weights…')
    start = time.perf_counter()
    # Path prevents repository resolution; admission rejects executable model code.
    model = load_model(folder)
    mx.synchronize()
    loading = time.perf_counter() - start
    result = measure(model, audio, seconds, mx.synchronize)
    result.update(loadSeconds=loading, sampleSHA256=SAMPLE_SHA256,
                  mlxVersion=importlib.metadata.version('mlx'),
                  mlxAudioVersion=importlib.metadata.version('mlx-audio'))
    emit('result', result=result)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('error', message=str(error))
        raise SystemExit(1)
