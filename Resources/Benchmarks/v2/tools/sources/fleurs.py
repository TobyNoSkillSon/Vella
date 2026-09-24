"""FLEURS test split (read Wikipedia/FLoRes sentences). Reference = raw_transcription (written case/punctuation).

Exposure: public benchmark for years; Nemotron 3.5 lists FLEURS in training. Used as a small read-speech
control and where no newer licensable source exists (Japanese, part of Mandarin).
"""
import csv, io, tarfile

from common import Candidate

REPO = 'google/fleurs'
REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
SOURCE = dict(
    id='fleurs', name='FLEURS', url='https://huggingface.co/datasets/google/fleurs', revision=REVISION,
    licence='CC BY 4.0', licenceUrl='https://huggingface.co/datasets/google/fleurs/blob/70bb2e84b976b7e960aa89f1c648e09c59f894dd/README.md',
    redistributable=True, released='2022-05',
    attribution='Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022), Google.',
    referenceProduction='FLoRes-101 sentences (human-written/translated prose) read aloud; raw_transcription keeps the written case and punctuation.',
)
_rows_cache = {}


def _rows(ctx, config):
    if config not in _rows_cache:
        path = ctx.hf_file(REPO, f'data/{config}/test.tsv', REVISION)
        rows = []
        with open(path, newline='', encoding='utf-8') as f:
            for r in csv.reader(f, delimiter='\t', quoting=csv.QUOTE_NONE):
                if len(r) != 7:
                    continue  # a handful of rows contain embedded tabs; skip rather than guess
                rows.append(dict(sid=r[0], file=r[1], raw=r[2], norm=r[3], samples=int(r[5]), gender=r[6]))
        _rows_cache[config] = rows
    return _rows_cache[config]


def candidates(ctx, language, config):
    out, seen = [], set()
    for r in sorted(_rows(ctx, config), key=lambda r: r['file']):
        if r['sid'] in seen:
            continue  # one recording per sentence: repeated renderings are not independent text
        seen.add(r['sid'])
        out.append(Candidate(
            key=f"{config}-{r['file'].removesuffix('.wav')}", language=language, duration=r['samples'] / 16000,
            reference=r['raw'], referenceType='formatted', group=f"sentence-{r['sid']}", speaker=None,
            conditions=('read',), stratum=f"gender-{r['gender']}", lexicalReference=None,
            origin=dict(repo=REPO, revision=REVISION, archive=f'data/{config}/audio/test.tar.gz', member=r['file'], sentenceId=r['sid']),
            extra=dict(config=config)))
    return out


def select(ctx, cands, target_seconds, language, config):
    from common import stratified_select
    return stratified_select(cands, target_seconds, max_duration=30.0)


_audio_cache = {}


def _archive(ctx, config):
    return ctx.hf_file(REPO, f'data/{config}/audio/test.tar.gz', REVISION)


def prepare(ctx, chosen):
    wanted = {}
    for c in chosen:
        wanted.setdefault(c.extra['config'], set()).add(c.origin['member'])
    for config, members in wanted.items():
        store = _audio_cache.setdefault(config, {})
        missing = members - set(store)
        if not missing:
            continue
        with tarfile.open(_archive(ctx, config), 'r:gz') as tar:
            for info in tar:
                name = info.name.rsplit('/', 1)[-1]
                if name in missing:
                    store[name] = tar.extractfile(info).read(); missing.discard(name)
                    if not missing:
                        break
        if missing:
            raise ValueError(f'{config}: {len(missing)} members not found in archive')


def extract(ctx, cand):
    from common import decode
    config = cand.extra['config']; member = cand.origin['member']
    if config not in _audio_cache:
        _audio_cache[config] = {}
    store = _audio_cache[config]
    if member not in store:
        # One sequential pass collects every member requested so far plus later ones on demand.
        with tarfile.open(_archive(ctx, config), 'r:gz') as tar:
            for info in tar:
                name = info.name.rsplit('/', 1)[-1]
                if name == member:
                    store[name] = tar.extractfile(info).read()
                    break
    samples, rate = decode(store.pop(member))
    return samples, rate, 'mean'
