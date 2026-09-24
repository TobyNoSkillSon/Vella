#!/usr/bin/env python3
"""Offline, owned Python-worker energy fixture. All 144 public clips; no app interaction."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import time
import uuid
import wave


def idle():
    status = json.loads((Path.home() / 'Library/Application Support/Vella/dictation-status.json').read_text())
    if status.get('phase') != 'idle':
        raise RuntimeError('Vella is not idle; aborting inference')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('phase', choices=['prepare', 'run'])
    p.add_argument('--suite', required=True, type=Path)
    p.add_argument('--wav-dir', required=True, type=Path)
    p.add_argument('--model', type=Path)
    p.add_argument('--worker', type=Path)
    p.add_argument('--result', type=Path)
    p.add_argument('--minimum-seconds', type=float, default=60)
    args = p.parse_args()
    manifest_path = args.suite / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    clips = manifest['clips']
    assert len(clips) == 144
    if args.phase == 'prepare':
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg: raise RuntimeError("ffmpeg is required for FLAC → PCM preparation")
        args.wav_dir.mkdir(parents=True, exist_ok=True)
        for clip in clips:
            source = args.suite / clip['file']
            assert hashlib.sha256(source.read_bytes()).hexdigest() == clip['sha256'], source
            target = args.wav_dir / (clip['id'] + '.wav')
            subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-i', str(source),
                            '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(target)],
                           check=True, timeout=30)
            with wave.open(str(target), 'rb') as audio:
                assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (1, 16000, 2)
                assert 0 < audio.getnframes() <= 960000
                if audio.getnframes() > 480000:
                    # The production worker accepts <=30 seconds per request.
                    raw = audio.readframes(audio.getnframes())
                    for part, chunk in enumerate((raw[:480000*2], raw[480000*2:]), 1):
                        with wave.open(str(args.wav_dir / f"{clip['id']}-part{part}.wav"), 'wb') as split:
                            split.setnchannels(1); split.setsampwidth(2); split.setframerate(16000)
                            split.writeframes(chunk)
        print(json.dumps({'clipsPrepared': len(clips), 'manifestSHA256': hashlib.sha256(manifest_path.read_bytes()).hexdigest()}))
        return
    assert args.model and args.model.is_dir() and args.worker and args.result
    idle()
    env = dict(os.environ, HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
               HF_HUB_DISABLE_TELEMETRY='1', PYTHONDONTWRITEBYTECODE='1')
    worker = subprocess.Popen([sys.executable, '-B', str(args.worker)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    requests = 0
    transcripts = hashlib.sha256()
    def request(clip):
        nonlocal requests
        base = args.wav_dir / (clip['id'] + '.wav')
        paths = ([args.wav_dir / f"{clip['id']}-part{part}.wav" for part in (1, 2)]
                 if clip['duration'] > 30 else [base])
        texts = []; metrics = []; last = None
        for audio in paths:
            if not audio.is_file(): raise RuntimeError(f'missing prepared WAV: {audio}')
            identifier = str(uuid.uuid4())
            worker.stdin.write((json.dumps({'id': identifier, 'model': str(args.model), 'audio': str(audio)}) + '\n').encode())
            worker.stdin.flush()
            line = worker.stdout.readline()
            if not line: raise RuntimeError('inference worker exited without response')
            response = json.loads(line)
            if response.get('id') != identifier or 'error' in response or 'text' not in response:
                raise RuntimeError(f'worker response failed: {response.get("error")}')
            requests += 1
            texts.append(response['text']); metrics.append(response['metrics']); last = response
        transcripts.update((clip['id'] + '\0' + ' '.join(texts) + '\n').encode())
        last['metrics']['audioSeconds'] = sum(m['audioSeconds'] for m in metrics)
        last['metrics']['modelLoaded'] = any(m['modelLoaded'] for m in metrics)
        return last
    try:
        cold = request(clips[0])
        if not cold['metrics']['modelLoaded']:
            raise RuntimeError('first request did not load the model')
        sys.stdout.write('READY\n'); sys.stdout.flush()
        if sys.stdin.readline() != 'GO\n':
            raise RuntimeError('missing measurement GO handshake')
        started = time.monotonic(); corpus_passes = 0; audio_seconds = 0.
        while True:
            idle()
            for clip in clips:
                idle()
                warm = request(clip)
                if warm['metrics']['modelLoaded']:
                    raise RuntimeError('unexpected reload during warmed suite')
                audio_seconds += warm['metrics']['audioSeconds']
            corpus_passes += 1
            if time.monotonic() - started >= args.minimum_seconds:
                break
        result = {'coldFirstRequest': cold['metrics'], 'warmWallSeconds': time.monotonic()-started,
                  'warmCorpusPasses': corpus_passes, 'warmAudioSeconds': audio_seconds,
                  'warmRequests': corpus_passes*(len(clips)+sum(c['duration']>30 for c in clips)), 'allRequestsIncludingCold': requests,
                  'transcriptsSHA256': transcripts.hexdigest(),
                  'manifestSHA256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  'pythonExecutable': sys.executable, 'modelPath': str(args.model)}
        args.result.write_text(json.dumps(result, indent=2) + '\n')
    finally:
        worker.stdin.close()
        try:
            worker.wait(timeout=15)
        except subprocess.TimeoutExpired:
            worker.terminate(); worker.wait(timeout=10)
        if worker.returncode != 0:
            raise RuntimeError(f'worker exited {worker.returncode}')


if __name__ == '__main__':
    main()
