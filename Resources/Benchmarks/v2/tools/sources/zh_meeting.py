"""AISHELL-4 official test, single-channel far-field meeting utterances.

The pinned public mirror splits each original eight-channel recording at TextGrid
interval boundaries; its WAV at index i is the i-th interval of the first tier.
The mirror's Apache badge is incorrect: the upstream corpus is CC BY-SA 4.0.
"""
import re
from huggingface_hub import HfApi
from common import Candidate, decode, stratified_select

REPO = 'shenyunhang/AISHELL-4'
REVISION = 'df062e4993eeb9873605f8c74d6fac1db0560799'
SOURCE = dict(
    id='aishell4', name='AISHELL-4 test (utterance mirror)', url='https://www.openslr.org/111/',
    revision=REVISION, licence='CC BY-SA 4.0', licenceUrl='https://www.openslr.org/111/',
    redistributable=True, released='2021',
    attribution='AISHELL-4, Beijing Shell Shell Technology Co., Ltd.; OpenSLR SLR111; utterance files redistributed by shenyunhang/AISHELL-4.',
    referenceProduction='Human TextGrid meeting annotation; first annotated speaker tier only; silence markup removed.',
)
INTERVAL = re.compile(r'intervals \[\d+\]:\s*xmin = ([\d.]+)\s*xmax = ([\d.]+)\s*text = "((?:[^"]|"")*)"')
TIER = re.compile(r'item \[\d+\]:\s*class = "IntervalTier"\s*name = "([^"]+)"(.*?)(?=\n    item \[\d+\]:|\Z)', re.S)
MARKER = re.compile(r'<[^>]+>')


def _tiers(text):
    result = []
    for name, body in TIER.findall(text):
        result.append((name, [(float(a), float(b), value.replace('""', '"')) for a, b, value in INTERVAL.findall(body)]))
    return result


def _speech(value):
    return bool(value.strip()) and not MARKER.sub('', value).strip() == ''


def candidates(ctx):
    paths = sorted(x.path for x in HfApi().list_repo_tree(REPO, path_in_repo='test/TextGrid',
                    revision=REVISION, repo_type='dataset') if x.path.endswith('.TextGrid'))
    out = []
    for path in paths:
        meeting = path.rsplit('/', 1)[-1].removesuffix('.TextGrid')
        tiers = _tiers(ctx.hf_file(REPO, path, REVISION).read_text(encoding='utf-8'))
        if len(tiers) < 2:
            raise ValueError(f'{meeting}: expected multiple speaker tiers')
        name, intervals = tiers[0]
        others = sorted((a, b) for _, records in tiers[1:] for a, b, t in records if _speech(t))
        for idx, (start, end, text) in enumerate(intervals):
            # Mirror indexes zero-based intervals, including silence; see source README.
            if not 2 <= end-start <= 30 or not _speech(text):
                continue
            if any(a < end and b > start for a, b in others):
                continue
            # <%> may signal unintelligible or other annotated vocal activity;
            # only <sil> is safely removable without changing spoken words.
            if MARKER.search(text) and any(tag != '<sil>' for tag in MARKER.findall(text)):
                continue
            reference = MARKER.sub('', text).strip()
            # '&...&' marks embedded/overlapping responses in the published transcript;
            # leave those intervals out rather than guessing which words this mic heard.
            if not reference or any(c in reference for c in ('[', ']', '&')):
                continue
            audio = f'test/wav/{meeting}/{idx:09d}.wav'
            out.append(Candidate(key=f'{meeting}-{idx:09d}', language='zh', duration=end-start,
                reference=reference, referenceType='normalised', group=meeting,
                speaker=f'{meeting}/{name}', conditions=('meeting', 'far-field'),
                stratum=meeting, origin=dict(repo=REPO, revision=REVISION, path=audio,
                    textGrid=path, tier=name, interval=idx, start=start, end=end,
                    channel='array-mic-1 (zero-based channel 0)'), extra={}))
    return sorted(out, key=lambda c: c.key)


def select(ctx, cands, target_seconds):
    return stratified_select(cands, target_seconds, max_group_seconds=65., min_duration=2., max_duration=30.)


def extract(ctx, cand):
    import soundfile as sf
    path = ctx.hf_file(cand.origin['repo'], cand.origin['path'], cand.origin['revision'])
    with sf.SoundFile(str(path)) as f:
        if f.channels != 8 or abs(f.frames/f.samplerate-cand.duration) > .04:
            raise ValueError(f'{path}: mirror cut/channel differs from TextGrid')
    # Check the mirror's separately published per-utterance text against the TextGrid.
    txtpath = cand.origin['path'].replace('/wav/', '/txt/').replace('.wav', '.txt')
    published = ctx.hf_file(REPO, txtpath, REVISION).read_text(encoding='utf-8').strip()
    if published != cand.reference and MARKER.sub('', published).strip() != cand.reference:
        raise ValueError(f'{txtpath}: transcript differs from TextGrid')
    samples, rate = decode(path)
    return samples, rate, 0  # fixed far-field array microphone 1, never a close headset
