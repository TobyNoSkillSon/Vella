#!/usr/bin/env python3
"""Private, offline Vella STT process. Stdout is reserved for newline JSON IPC."""
import contextlib
import gc
import inspect
import io
import json
import os
import pathlib
import resource
import signal
import stat
import sys
import time
import uuid
import wave

CACHE_BYTES = 64 * 1024 * 1024
MAX_LINE = 16 * 1024
REQUEST_SECONDS = 120
MAX_AUDIO = 2 * 1024 * 1024
MESSAGES = {'invalid': 'Invalid local transcription request.',
            'no_speech': 'No speech was recognized.',
            'memory': 'Insufficient memory for transcription.',
            'inference': 'Local transcription failed.'}


class Invalid(ValueError):
    pass


def offline():
    for name in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE', 'HF_HUB_DISABLE_TELEMETRY',
                 'HF_HUB_DISABLE_PROGRESS_BARS'):
        os.environ[name] = '1'
    # Defense in depth for library post-load hooks; this process needs no sockets.
    import socket
    def denied(*args, **kwargs):
        raise OSError('Networking is disabled in the Vella worker')
    socket.socket.connect = denied
    socket.socket.connect_ex = denied
    socket.create_connection = denied


def validate_audio(value):
    if not isinstance(value, str) or not pathlib.Path(value).is_absolute():
        raise Invalid()
    path = pathlib.Path(value).resolve(strict=True)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or not 44 <= info.st_size <= MAX_AUDIO:
        raise Invalid()
    # Read a bounded snapshot for structural validation; only a path reaches MLX Audio.
    with path.open('rb') as source:
        data = source.read(MAX_AUDIO + 1)
    if len(data) > MAX_AUDIO:
        raise Invalid()
    with wave.open(io.BytesIO(data)) as audio:
        frames = audio.getnframes()
        if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth(),
                audio.getcomptype()) != (1, 16000, 2, 'NONE') or not 0 < frames <= 480000:
            raise Invalid()
        if len(audio.readframes(frames)) != frames * 2:
            raise Invalid()
    return path, frames / 16000


def process_memory():
    result = {'processPeakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
              * (1 if sys.platform == 'darwin' else 1024)}
    if sys.platform == 'darwin':
        try:
            import ctypes
            class Usage(ctypes.Structure):
                _fields_ = [('uuid', ctypes.c_byte * 16)] + [(name, ctypes.c_uint64) for name in
                    ('user', 'system', 'wakeups', 'interrupts', 'pageins', 'wired',
                     'resident', 'footprint', 'start', 'exit', 'child_user', 'child_system',
                     'child_wakeups', 'child_interrupts', 'child_pageins', 'child_elapsed',
                     'disk_read', 'disk_write', 'qos_default', 'qos_maintenance', 'qos_background',
                     'qos_utility', 'qos_legacy', 'qos_initiated', 'qos_interactive',
                     'billed_system', 'serviced_system', 'logical_writes', 'peak_footprint',
                     'instructions', 'cycles', 'billed_energy', 'serviced_energy',
                     'interval_footprint', 'runnable')]
            usage = Usage()
            lib = ctypes.CDLL('/usr/lib/libproc.dylib')
            if lib.proc_pid_rusage(os.getpid(), 4, ctypes.byref(usage)) == 0:
                result.update(processRSSBytes=usage.resident, processFootprintBytes=usage.footprint,
                              processPeakFootprintBytes=usage.peak_footprint)
        except (OSError, AttributeError):
            pass
    return result


def text_of(value):
    value = value.get('text', '') if isinstance(value, dict) else (
        value if isinstance(value, str) else getattr(value, 'text', ''))
    return value if isinstance(value, str) else ''


class Worker:
    def __init__(self, mx, loader, admission, cache_bytes=CACHE_BYTES):
        self.mx, self.loader, self.admission = mx, loader, admission
        self.model = self.path = None
        self.cache_bytes = cache_bytes
        if cache_bytes is not None:  # None is used only by the QA comparison harness.
            mx.set_cache_limit(cache_bytes)

    def cleanup(self):
        self.mx.synchronize()
        gc.collect()
        self.mx.clear_cache()

    def release(self):
        self.model = self.path = None
        self.cleanup()

    def infer(self, path):
        kwargs = dict(verbose=False, max_tokens=1024, chunk_duration=30.0, stream=False)
        signature = inspect.signature(self.model.generate)
        kwargs = {key: value for key, value in kwargs.items() if key in signature.parameters}
        result = self.model.generate(str(path), **kwargs)
        if hasattr(result, '__next__'):
            try:
                return ''.join(text_of(item) for item in result).strip()
            finally:
                close = getattr(result, 'close', None)
                if close:
                    close()
        return text_of(result).strip()

    def perform(self, request, metrics):
        # Validation happens before any load or generation; never resolve repository IDs.
        try:
            if not isinstance(request, dict) or set(request) != {'id', 'model', 'audio'}:
                raise Invalid()
            if not isinstance(request['id'], str):
                raise Invalid()
            uuid.UUID(request['id'])
            model = request['model']
            if not isinstance(model, str) or not pathlib.Path(model).is_absolute():
                raise Invalid()
            path = pathlib.Path(model).resolve(strict=True)
            audio, seconds = validate_audio(request['audio'])
            if path != self.path:
                path = self.admission(path)
        except Exception:
            raise Invalid() from None
        cold = path != self.path
        metrics.update(audioSeconds=seconds, modelLoaded=cold, loadSeconds=0.0,
                       mlxPeakPhase='load_and_first_request' if cold else 'warm_request',
                       allocatorCacheLimitBytes=self.cache_bytes)
        if cold:
            self.release()  # Drop old tensors BEFORE loading a replacement.
        self.mx.reset_peak_memory()
        if cold:
            start = time.perf_counter()
            self.model = self.loader(path)
            self.mx.synchronize()
            self.path = path
            metrics['loadSeconds'] = time.perf_counter() - start
            metrics['loadPeakMLXBytes'] = self.mx.get_peak_memory()
        start = time.perf_counter()
        text = self.infer(audio)
        self.mx.synchronize()
        metrics['inferenceSeconds'] = time.perf_counter() - start
        metrics['peakMLXBytes'] = self.mx.get_peak_memory()
        return text

    def handle(self, request):
        request_start = time.perf_counter()
        identifier = request.get('id') if isinstance(request, dict) else None
        try:
            if not isinstance(identifier, str):
                raise ValueError()
            uuid.UUID(identifier)
        except ValueError:
            identifier = None
        metrics = {}
        response = {'id': identifier}
        # Never forward exception messages: model exceptions may contain recognized speech.
        try:
            text = self.perform(request, metrics)
            if text:
                response.update(text=text, metrics=metrics)
            else:
                response['error'] = {'code': 'no_speech', 'message': MESSAGES['no_speech']}
        except Exception as error:
            code = 'invalid' if isinstance(error, Invalid) else 'memory' if (
                isinstance(error, MemoryError) or any(token in str(error).lower() for token in
                ('out of memory', 'memory allocation', 'metal allocation', 'insufficient memory'))
            ) else 'inference'
            response['error'] = {'code': code, 'message': MESSAGES[code]}
            if code != 'invalid':
                self.model = self.path = None
        # Except block has ended: its traceback (and generate locals) is no longer held.
        try:
            cleanup_start = time.perf_counter()
            self.cleanup()
            if 'metrics' in response:
                metrics.update(cleanupSeconds=time.perf_counter() - cleanup_start,
                               requestSeconds=time.perf_counter() - request_start,
                               activeMLXBytes=self.mx.get_active_memory(),
                               cacheMLXBytes=self.mx.get_cache_memory(), **process_memory())
        except Exception:
            self.model = self.path = None
            response = {'id': identifier, 'error': {'code': 'memory', 'message': MESSAGES['memory']}}
        return response


def serve(worker, source, output):
    # SIG_DFL terminates at the OS level even if native inference holds the GIL.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(0)
    while True:
        line = source.readline(MAX_LINE + 1)
        if not line:
            break
        signal.alarm(REQUEST_SECONDS)
        try:
            if len(line) > MAX_LINE:
                while line and not line.endswith(b'\n'):
                    line = source.readline(MAX_LINE + 1)
                request = None
            else:
                try:
                    request = json.loads(line)
                except (ValueError, UnicodeError, RecursionError):
                    request = None
            response = worker.handle(request)
            output.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + '\n')
            output.flush()
            del request, response, line
        finally:
            # No deadline while waiting for another request; EOF exits immediately.
            signal.alarm(0)


def main():
    # Suppress Python AND native library output for the entire worker lifetime. Only
    # the duplicated descriptor is used for intentional protocol responses.
    output = os.fdopen(os.dup(1), 'w', buffering=1)
    with open(os.devnull, 'w') as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            offline()
            import mlx.core as mx
            from mlx_audio.stt.utils import load_model
            from calibration_worker import validate_local
            worker = Worker(mx, load_model, validate_local)
            try:
                serve(worker, sys.stdin.buffer, output)
            finally:
                worker.release()
                output.close()


if __name__ == '__main__':
    main()
