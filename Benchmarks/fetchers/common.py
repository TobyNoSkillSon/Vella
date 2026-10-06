"""Shared build library for Vella benchmark v2.

Every clip is rebuilt from a pinned upstream source: fetch minimal bytes -> decode ->
explicit channel policy -> soxr VHQ resample to 16 kHz -> int16 PCM -> FLAC.
The PCM SHA-256 (little-endian int16 samples) is the reproducibility identity; the FLAC
file SHA-256 is recorded too, but it depends on the libsndfile encoder version.
"""
from __future__ import annotations

import dataclasses, hashlib, io, json, os, pathlib, random, re, sys, time, unicodedata
from email.utils import parsedate_to_datetime
from typing import Callable, Iterable

import numpy as np
import soundfile as sf
import soxr

SUITE = pathlib.Path(__file__).resolve().parents[1]
RATE = 16000
SEED = 20260924
USER_AGENT = 'vella-benchmark-v2-builder'
HTTP_ATTEMPTS = 4
HTTP_RETRY_SECONDS = 60.0
HTTP_RETRY_STATUSES = {429, 500, 502, 503, 504}


def _retry_after(value: str | None) -> float:
    """Retry-After is either seconds or an HTTP date; invalid values add no delay."""
    if value is None:
        return 0.0
    try:
        return max(0.0, float(value))
    except ValueError:
        try:
            return max(0.0, parsedate_to_datetime(value).timestamp() - time.time())
        except (TypeError, ValueError, OverflowError):
            return 0.0


@dataclasses.dataclass
class Candidate:
    """One selectable segment. Cheap metadata only; audio is fetched in extract()."""
    key: str                      # unique within the source (stable upstream ID + offsets)
    language: str                 # BCP-47-ish: en, pl, de, fr, es, sv, tr, ja, zh, ko
    duration: float               # seconds, from metadata (verified after extraction)
    reference: str                # reference exactly as published (formatted if the source is)
    referenceType: str            # 'formatted' | 'normalised'
    group: str                    # independence unit for sampling/bootstrap (speaker, call, meeting, talk)
    speaker: str | None = None
    conditions: tuple = ()        # e.g. ('spontaneous', 'far-field', 'accented:en-IN')
    stratum: str = ''             # stratification key for selection
    lexicalReference: str | None = None   # separate lexical text if the source publishes one
    origin: dict = dataclasses.field(default_factory=dict)  # path, sourceSha256, start, end, channel...
    extra: dict = dataclasses.field(default_factory=dict)   # adapter-private data needed by extract()


class Context:
    def __init__(self, cache: pathlib.Path, allocation: str, log: pathlib.Path | None = None):
        self.cache = pathlib.Path(cache); self.cache.mkdir(parents=True, exist_ok=True)
        self.allocation = allocation
        self.log = log or self.cache / 'downloads.jsonl'

    def note_download(self, what: str, nbytes: int):
        with self.log.open('a') as f:
            f.write(json.dumps(dict(at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), allocation=self.allocation, what=what, bytes=nbytes)) + '\n')

    # ---- fetching (all pinned) ----
    def http_request(self, url: str, *, method: str = 'GET', session=None,
                     consume: Callable | None = None, **kwargs):
        """Retry transport failures only, including interrupted response bodies.

        Four attempts share a 60-second retry deadline. Socket timeouts are bounded
        by the remaining budget; successful streaming downloads can take longer.
        Callers must verify hashes, revisions and range semantics after this returns.
        """
        import requests
        client = session or requests
        headers = {'User-Agent': USER_AGENT, **kwargs.pop('headers', {})}
        deadline = time.monotonic() + HTTP_RETRY_SECONDS
        for attempt in range(1, HTTP_ATTEMPTS + 1):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise requests.exceptions.Timeout('HTTP retry deadline exceeded')
            try:
                with client.request(method, url, headers=headers,
                                    timeout=(min(5.0, remaining / 2), min(10.0, remaining / 2)),
                                    **kwargs) as response:
                    response.raise_for_status()
                    if consume is not None:
                        return consume(response)
                    # Consume inside the retry scope, then close the connection.
                    response.content
                    return response
            except (requests.exceptions.HTTPError, requests.exceptions.ConnectionError,
                    requests.exceptions.Timeout, requests.exceptions.ChunkedEncodingError) as error:
                retry_after = 0.0
                if isinstance(error, requests.exceptions.HTTPError):
                    if error.response is None or error.response.status_code not in HTTP_RETRY_STATUSES:
                        raise
                    reason = f'HTTP {error.response.status_code}'
                    retry_after = _retry_after(error.response.headers.get('Retry-After'))
                else:
                    if isinstance(error, requests.exceptions.SSLError):
                        raise
                    reason = type(error).__name__
                delay = max(retry_after, random.uniform(1.0, 2.0) * 2 ** (attempt - 1))
                if attempt == HTTP_ATTEMPTS or delay >= deadline - time.monotonic():
                    raise
                # Do not log signed audio URL query strings or multiline errors.
                label = url.partition('?')[0].replace('\n', '').replace('\r', '')
                print(f'fetch retry {attempt + 1}/{HTTP_ATTEMPTS}: {method} {label}: {reason}; waiting {delay:.2f}s',
                      file=sys.stderr, flush=True)
                time.sleep(delay)
                if time.monotonic() >= deadline:
                    raise

    def hf_file(self, repo: str, path: str, revision: str, repo_type: str = 'dataset') -> pathlib.Path:
        from huggingface_hub import hf_hub_download
        assert re.fullmatch(r'[0-9a-f]{40}', revision), 'pin a full commit SHA'
        target = self.cache / 'hf' / repo.replace('/', '__') / revision / path
        if target.exists():
            return target
        local = hf_hub_download(repo, path, revision=revision, repo_type=repo_type,
                                local_dir=self.cache / 'hf' / repo.replace('/', '__') / revision, etag_timeout=60)
        self.note_download(f'hf:{repo}@{revision}/{path}', pathlib.Path(local).stat().st_size)
        return pathlib.Path(local)

    def hf_open(self, repo: str, path: str, revision: str, repo_type: str = 'dataset'):
        """Range-readable remote file object (for parquet row-group reads without a full download)."""
        from huggingface_hub import HfFileSystem
        assert re.fullmatch(r'[0-9a-f]{40}', revision), 'pin a full commit SHA'
        prefix = 'datasets/' if repo_type == 'dataset' else ''
        rev = revision
        return HfFileSystem().open(f'{prefix}{repo}@{rev}/{path}', 'rb', block_size=4 * 1024 * 1024)

    def http_file(self, url: str, sha256: str | None = None, name: str | None = None) -> pathlib.Path:
        target = self.cache / 'http' / (name or hashlib.sha256(url.encode()).hexdigest()[:16] + '-' + url.rsplit('/', 1)[-1][:80])
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_suffix(target.suffix + '.part')
            def write_response(r):
                with tmp.open('wb') as f:
                    for block in r.iter_content(8 * 1024 * 1024):
                        f.write(block)
            try:
                self.http_request(url, stream=True, consume=write_response)
            except BaseException:
                # A failed download is never left available as a cached file.
                tmp.unlink(missing_ok=True)
                raise
            tmp.replace(target)
            self.note_download(f'http:{url}', target.stat().st_size)
        if sha256 and sha_file(target) != sha256:
            raise ValueError(f'checksum mismatch for {url}')
        return target

    def http_range(self, url: str, start: int, end_inclusive: int) -> bytes:
        r = self.http_request(url, headers={'Range': f'bytes={start}-{end_inclusive}'})
        if r.status_code != 206:
            raise ValueError(f'range request not honoured: {r.status_code}')
        self.note_download(f'range:{url}:{start}-{end_inclusive}', len(r.content))
        return r.content


def sha_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def sha_file(path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


# ---- audio ----
def decode(data: bytes | str | pathlib.Path, start: float | None = None, end: float | None = None):
    """Decode with libsndfile (WAV/FLAC/OGG/MP3). Returns float64 (frames, channels), rate."""
    src = io.BytesIO(data) if isinstance(data, (bytes, bytearray)) else str(data)
    with sf.SoundFile(src) as f:
        rate = f.samplerate
        a = 0 if start is None else int(round(start * rate))
        b = f.frames if end is None else min(f.frames, int(round(end * rate)))
        f.seek(a)
        samples = f.read(b - a, dtype='float64', always_2d=True)
    return samples, rate


def to_mono(samples: np.ndarray, channel: int | str = 'mean') -> np.ndarray:
    """Explicit channel policy: an integer selects one channel; 'mean' averages all channels."""
    if samples.ndim == 1:
        return samples
    if channel == 'mean':
        return samples.mean(axis=1)
    return samples[:, int(channel)]


def finalize(samples: np.ndarray, rate: int) -> np.ndarray:
    """Mono float -> 16 kHz int16 with soxr VHQ. Deterministic for pinned soxr/numpy."""
    assert samples.ndim == 1
    if rate != RATE:
        samples = soxr.resample(samples, rate, RATE, quality='VHQ')
    return np.clip(np.round(samples * 32767.0), -32768, 32767).astype('<i2')


def pcm_sha(pcm: np.ndarray) -> str:
    return sha_bytes(pcm.astype('<i2').tobytes())


def write_flac(path: pathlib.Path, pcm: np.ndarray):
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), pcm, RATE, format='FLAC', subtype='PCM_16')


# ---- text ----
def clean_text(text: str) -> str:
    """Only Unicode NFC + whitespace collapse; never edits words or punctuation."""
    return ' '.join(unicodedata.normalize('NFC', text).split())


def safe_id(text: str) -> str:
    return re.sub(r'[^A-Za-z0-9_.-]+', '-', text).strip('-')[:120]


# ---- selection ----
def stratified_select(cands: list[Candidate], target_seconds: float, seed: int = SEED,
                      max_group_seconds: float | None = None, min_duration: float = 1.0,
                      max_duration: float | None = None) -> list[Candidate]:
    """Seeded, reproducible, stratified selection.

    Candidates are sorted by key (order-independent), filtered by duration, shuffled with
    `seed`, then drawn round-robin across strata (and across groups within a stratum) until
    the target duration is reached. `max_group_seconds` caps one speaker/recording's share.
    """
    rng = random.Random(seed)
    pool = sorted((c for c in cands if c.duration >= min_duration and (max_duration is None or c.duration <= max_duration)),
                  key=lambda c: c.key)
    rng.shuffle(pool)
    strata: dict[str, list[Candidate]] = {}
    for c in pool:
        strata.setdefault(c.stratum, []).append(c)
    order = sorted(strata)
    rng.shuffle(order)
    chosen: list[Candidate] = []; total = 0.0; used: dict[str, float] = {}
    cursors = {s: 0 for s in order}
    while total < target_seconds and any(cursors[s] < len(strata[s]) for s in order):
        for s in order:
            items = strata[s]
            while cursors[s] < len(items):
                c = items[cursors[s]]; cursors[s] += 1
                if max_group_seconds and used.get(c.group, 0) + c.duration > max_group_seconds:
                    continue
                chosen.append(c); total += c.duration; used[c.group] = used.get(c.group, 0) + c.duration
                break
            if total >= target_seconds:
                break
    return sorted(chosen, key=lambda c: c.key)
