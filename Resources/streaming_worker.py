#!/usr/bin/env python3
"""Offline, single-session native incremental Nemotron/Voxtral JSONL worker.

Greedy RNNT prefixes are immutable. Long utterances drain complete-word prefixes
without resetting acoustic or predictor context; partial is the remaining suffix.
Only low-energy endpoints reset context. No waveform or token history is retained.
"""
import base64
import collections
import codecs
import gc
import json
import math
import os
from pathlib import Path
import signal
import struct
import sys
import uuid
import weakref

MAX_LINE = 10000
MAX_FRAMES = 1600
BLOCK = 320  # fixed 20 ms endpoint decisions independent of transport framing
PRE_ROLL = 15  # 300 ms
TRAILING = 40  # 800 ms
ENERGY = 0.0003  # deliberately conservative, not a speech classifier
CACHE_BYTES = 64 * 1024 * 1024
ATT_CONTEXT = (56, 3)  # supported native 4 x 80ms encoder chunks, not model's 1.12s default
VOXTRAL_DELAY_MS = 480
VOXTRAL_INPUT_FRAMES = 1280
VOXTRAL_STEP_TOKENS = 64
VOXTRAL_FINAL_STEPS = 32
VOXTRAL_SESSION_TOKENS = 4096
BENCHMARK_PARAMETERS = {
    'nemotron_asr': {
        'api': 'StreamingLogMelSpectrogram/ConformerStreamingState/persistent RNNT',
        'attContextSize': list(ATT_CONTEXT), 'cacheLimitBytes': CACHE_BYTES,
        'language': 'model.default_language', 'maxSymbols': 'model.max_symbols or 10',
    },
    'voxtral_realtime': {
        'api': 'create_streaming_session/feed/step/close',
        'temperature': 0.0, 'transcriptionDelayMs': VOXTRAL_DELAY_MS,
        'inputBufferFrames': VOXTRAL_INPUT_FRAMES,
        'maxDecodeTokensPerStep': VOXTRAL_STEP_TOKENS,
        'constructorMaxTokens': VOXTRAL_SESSION_TOKENS,
        'utteranceTokenLimit': None,
        'finalStepLimit': VOXTRAL_FINAL_STEPS,
        'finish': 'close; one step then at most finalStepLimit additional steps until done; fail if not done',
        'cacheLimitBytes': CACHE_BYTES,
        'encoderSlidingWindow': 750, 'decoderSlidingWindow': 8192,
        'retention': 'retire consumed adapter frames and PCM; clear generated/_prev_text each step; retain native rotating KV and positions',
        'text': 'incremental token_bytes UTF-8 decoder; hold incomplete byte sequences until safe; flush final remainder',
    },
}


class Invalid(ValueError):
    pass


def offline():
    for key in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE', 'HF_HUB_DISABLE_TELEMETRY',
                'HF_HUB_DISABLE_PROGRESS_BARS'):
        os.environ[key] = '1'
    import socket
    def denied(*args, **kwargs):
        raise OSError('Offline worker')
    socket.socket.connect = denied
    socket.socket.connect_ex = denied
    socket.create_connection = denied


def model_path(value):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise Invalid()
    path = Path(value).resolve(strict=True)
    config = path / 'config.json'
    if not path.is_dir() or not config.is_file() or config.stat().st_size > 1024 * 1024:
        raise Invalid()
    data = json.loads(config.read_text())
    if (not isinstance(data, dict) or 'auto_map' in data or
            data.get('model_type') not in ('nemotron_asr', 'voxtral_realtime') or
            not any(path.glob('*.safetensors'))):
        raise Invalid()
    tokenizer = path / 'tokenizer_config.json'
    if tokenizer.exists():
        if not tokenizer.is_file() or tokenizer.stat().st_size > 1024 * 1024:
            raise Invalid()
        tokenizer_data = json.loads(tokenizer.read_text())
        if not isinstance(tokenizer_data, dict) or 'auto_map' in tokenizer_data:
            raise Invalid()
    return path


def pcm(value):
    if not isinstance(value, str) or len(value) > 8536:
        raise Invalid()
    raw = base64.b64decode(value, validate=True)
    if not raw or len(raw) % 4 or len(raw) > MAX_FRAMES * 4:
        raise Invalid()
    samples = struct.unpack('<' + 'f' * (len(raw) // 4), raw)
    # Resampling can overshoot normalized full scale. Preserve finite PCM unchanged
    # (including inference), while rejecting corrupt/unbounded amplitudes.
    if any(not math.isfinite(x) or abs(x) > 16 for x in samples):
        raise Invalid()
    return samples


class Native:
    def __new__(cls, path):
        if cls is Native and json.loads((path / 'config.json').read_text()).get('model_type') == 'voxtral_realtime':
            return Voxtral(path)
        return super().__new__(cls)

    def __init__(self, path):
        import mlx.core as mx
        from mlx_audio.stt.utils import load_model
        from mlx_audio.stt.models.nemotron_asr.audio import StreamingLogMelSpectrogram
        from mlx_audio.stt.models.nemotron_asr.streaming import ConformerStreamingState
        from mlx_audio.stt.models.nemotron_asr import tokenizer
        self.mx, self.frontend_type, self.state_type = mx, StreamingLogMelSpectrogram, ConformerStreamingState
        self.tok = tokenizer
        mx.set_cache_limit(CACHE_BYTES)
        self.model = load_model(str(path))
        mx.eval(self.model.parameters())
        self.reset()

    def reset(self):
        self.frontend = self.frontend_type(self.model.preprocessor_config)
        self.encoder = self.state_type(self.model.encoder,
                                       att_context_size=list(ATT_CONTEXT))
        self.last = self.model.blank_id
        self.hidden = None
        self.text = ''
        self.mx.clear_cache()

    def push(self, samples, final=False):
        mx, model = self.mx, self.model
        mel = (self.frontend.flush() if final and not len(samples) else
               self.frontend.push(mx.array(samples, dtype=mx.float32), final=final))
        for encoded in self.encoder.push(mel, final=final):
            features = model.apply_prompt(encoded, model.default_language)
            self.encoder.materialize(features)
            for time in range(features.shape[1]):
                feature = features[:, time:time + 1]
                for _ in range(model.max_symbols or 10):
                    token = mx.array([[self.last]], dtype=mx.int32) if self.last != model.blank_id else None
                    output, (h, c) = model.decoder(token, self.hidden)
                    prediction = int(mx.argmax(model.joint(feature, output.astype(feature.dtype))))
                    if prediction == model.blank_id:
                        break
                    self.last = prediction
                    self.hidden = (h.astype(feature.dtype), c.astype(feature.dtype))
                    mx.eval(*self.hidden)
                    self.text += self.tok.decode([prediction], model.vocabulary)
        # Also evaluate pending mel on calls that do not yet emit an encoder chunk.
        self.encoder.materialize()
        if self.encoder.pending is not None:
            mx.eval(self.encoder.pending)
        mx.clear_cache()

    def drain(self, final=False):
        if final:
            result, self.text = self.text.strip(), ''
            return result
        encoded = self.text.encode('utf-8')
        if len(encoded) < 2048:
            return ''
        cut = self.text.rfind(' ', 0, len(encoded[:2048].decode('utf-8', errors='ignore')))
        if cut <= 0:
            # No safe word boundary: fail explicitly, never silently drop a suffix.
            if len(encoded) > 8192:
                raise RuntimeError('Text boundary unavailable')
            return ''
        result, self.text = self.text[:cut].strip(), self.text[cut:]
        return result

    def close(self):
        self.frontend = self.encoder = self.hidden = self.model = None
        self.mx.synchronize()
        gc.collect()
        self.mx.clear_cache()


class Voxtral:
    """Pinned MLX Audio 0.5.1 session, with bounded retention fixes.

    Native KV caches rotate, but upstream retains raw PCM, adapter frames and
    every decoded token. Retire consumed data without resetting model positions.
    Decode token bytes incrementally: upstream slices replacement-character text
    deltas, which is not prefix safe when a UTF-8 character spans tokens.
    """
    drain = Native.drain
    def __init__(self, path):
        import mlx.core as mx
        from mlx_audio.stt.utils import load_model
        self.mx = mx
        mx.set_cache_limit(CACHE_BYTES)
        self.model = load_model(str(path))
        mx.eval(self.model.parameters())
        self.reset()

    def reset(self):
        self.stream = self.model.create_streaming_session(
            max_tokens=VOXTRAL_SESSION_TOKENS, temperature=0.0,
            transcription_delay_ms=VOXTRAL_DELAY_MS)
        s = self.stream
        s._vella_base = 0
        # These private hooks are deliberately pinned to the inspected runtime.
        stream = weakref.proxy(s)  # hooks must not keep old endpoint KV alive
        def count():
            return stream._vella_base + sum(a.shape[0] for a in stream._adapter_frames)
        original_at = type(s)._adapter_at
        def at(pos):
            return original_at(stream, pos - stream._vella_base)
        s._n_adapter = count
        s._adapter_at = at
        self.decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        self.pending_audio = []  # one 80-ms native audio token, never full history
        self.text = ''
        self.mx.clear_cache()

    def _step(self):
        s, mx = self.stream, self.mx
        # The cap is a yield bound, not an utterance truncation: generated is
        # drained every step, while decoder positions and KV state persist.
        s.step(max_decode_tokens=VOXTRAL_STEP_TOKENS)
        raw = b''.join(self.model._tokenizer.token_bytes(t) for t in s.generated)
        self.text += self.decoder.decode(raw, final=s.done)
        s.generated.clear()
        s._prev_text = ''
        if s._prefilled:
            drop = min(s._pos - s._vella_base,
                       sum(a.shape[0] for a in s._adapter_frames))
            s._vella_base += drop
            kept = []
            for a in s._adapter_frames:
                n = min(drop, a.shape[0])
                drop -= n
                if n < a.shape[0]:
                    kept.append(mx.array(a[n:]))
            s._adapter_frames = kept
        mel = s._smel
        mel.trim(max(0, mel._next_k * mel.hop_length - mel.window_size))
        # numpy slices otherwise retain the entire allocation behind a tiny tail.
        mel._buf = mel._buf.copy()
        arrays = list(s._adapter_frames)
        for cache in s._senc._caches + (s._cache or []):
            arrays.extend(a for a in (cache.keys, cache.values) if a is not None)
        for conv in (s._sconv._c0, s._sconv._c1):
            if conv._state is not None:
                arrays.append(conv._state)
        if s._sproj._buf is not None:
            arrays.append(s._sproj._buf)
        if arrays:
            mx.eval(*arrays)
        mx.clear_cache()

    def push(self, samples, final=False):
        s = self.stream
        if s.done:
            raise RuntimeError('Native stream ended before audio endpoint')
        self.pending_audio.extend(samples)
        if not final and len(self.pending_audio) < VOXTRAL_INPUT_FRAMES:
            return
        if self.pending_audio:
            s.feed(self.pending_audio)
            self.pending_audio = []
        if final:
            s.close()
        self._step()
        if final:
            for _ in range(VOXTRAL_FINAL_STEPS):
                if s.done:
                    break
                self._step()
            if not s.done:
                raise RuntimeError('Native stream failed to finish')
        elif s.done:
            raise RuntimeError('Native stream ended before audio endpoint')

    def close(self):
        self.stream = self.decoder = self.model = None
        self.mx.synchronize()
        gc.collect()
        self.mx.clear_cache()


def native(path):
    return Native(path)


class Session:
    def __init__(self, factory=native):
        self.factory = factory
        self.native = None
        self.frames = 0
        self.active = False
        self.silent = 0
        self.pending = []
        self.preroll = collections.deque(maxlen=PRE_ROLL)
        self.done = False

    def block(self, samples):
        quiet = sum(x*x for x in samples) / len(samples) < ENERGY**2
        if not self.active:
            self.preroll.append(samples)
            if quiet:
                return ''
            self.active = True
            for block in self.preroll:
                self.native.push(block)
            self.preroll.clear()
        else:
            self.native.push(samples)
        self.silent = self.silent + 1 if quiet else 0
        if self.silent >= TRAILING:
            return self.endpoint()
        return self.native.drain()

    def endpoint(self):
        if not self.active:
            return ''
        self.native.push([], final=True)
        text = self.native.drain(final=True)
        # Successful native completion is authoritative, including empty text.
        self.native.reset()
        self.active, self.silent = False, 0
        return text

    def handle(self, request):
        if not isinstance(request, dict) or not isinstance(request.get('id'), str):
            raise Invalid()
        uuid.UUID(request['id'])
        op = request.get('op')
        expected = {'id', 'op', 'model'} if op == 'start' else ({'id', 'op', 'pcm'} if op == 'audio' else {'id', 'op'})
        if set(request) != expected or self.done:
            raise Invalid()
        reply = {'id': request['id']}
        if op == 'start':
            if self.native is not None:
                raise Invalid()
            self.native = self.factory(model_path(request['model']))
            return dict(reply, frames=0)
        if self.native is None:
            raise Invalid()
        committed = []
        if op == 'audio':
            samples = pcm(request['pcm'])
            self.frames += len(samples)
            self.pending.extend(samples)
            while len(self.pending) >= BLOCK:
                block, self.pending = self.pending[:BLOCK], self.pending[BLOCK:]
                committed.append(self.block(block))
        elif op == 'finish':
            if self.pending:
                committed.append(self.block(self.pending))
                self.pending = []
            committed.append(self.endpoint())
            self.done = True
        else:
            raise Invalid()
        reply.update(frames=self.frames, partial=self.native.text.strip() if self.active else '',
                     committed=' '.join(x for x in committed if x))
        if len((reply['committed'] + reply['partial']).encode('utf-8')) > 8192:
            raise RuntimeError('Streaming text delivery bound exceeded')
        if self.done:
            reply['done'] = True
        return reply

    def close(self):
        if self.native is not None:
            self.native.close()
        self.native = None
        self.pending.clear()
        self.preroll.clear()


def main():
    # Redirect OS descriptors too: native libraries must never leak diagnostics.
    output = os.fdopen(os.dup(sys.stdout.fileno()), 'w', buffering=1)
    with open(os.devnull, 'w') as null:
        os.dup2(null.fileno(), 1)
        os.dup2(null.fileno(), 2)
    offline()
    session = Session()
    def expired(*args):
        raise TimeoutError()
    signal.signal(signal.SIGALRM, expired)
    signal.signal(signal.SIGTERM, expired)
    try:
        while not session.done:
            ident = None
            try:
                signal.alarm(120)  # includes abandoned-IPC idle and model operations
                line = sys.stdin.buffer.readline(MAX_LINE + 1)
                if not line:
                    break
                if len(line) > MAX_LINE or not line.endswith(b'\n'):
                    raise Invalid()
                request = json.loads(line)
                if isinstance(request, dict) and isinstance(request.get('id'), str):
                    try:
                        uuid.UUID(request['id'])
                        ident = request['id']
                    except ValueError:
                        pass
                reply = session.handle(request)
            except TimeoutError:
                reply = {'id': ident, 'error': 'Local streaming transcription failed.'}
                session.done = True
            except (Invalid, ValueError, TypeError, OSError):
                reply = {'id': ident, 'error': 'Invalid local streaming request.'}
                session.done = True
            except BaseException:
                reply = {'id': ident, 'error': 'Local streaming transcription failed.'}
                session.done = True
            finally:
                signal.alarm(0)
            output.write(json.dumps(reply, ensure_ascii=True) + '\n')
    finally:
        signal.alarm(0)
        session.close()
        output.close()


if __name__ == '__main__':
    main()
