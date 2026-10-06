"""Resolve hash-pinned third-party references from a local, uncommitted cache.

Only fetch.py downloads text. Runners and scorers fail closed when it is missing.
Hashes cover the UTF-8 bytes of the frozen reference strings, after the original
suite builder's NFC/whitespace cleanup, without changing the scoring rules.
"""
import hashlib
import importlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_ROOT = ROOT / '.data/references'
FETCHERS = {'polish-tedx': 'polish_tedx', 'mediaspeech': 'mediaspeech'}


def text_sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def validate(clip, values):
    for field in ('reference', 'lexicalReference'):
        expected = clip.get(field + 'Sha256')
        if expected is not None:
            if not re.fullmatch(r'[0-9a-f]{64}', expected):
                raise ValueError(f"invalid {field} hash: {clip['id']}")
            value = values.get(field)
            if not isinstance(value, str) or text_sha(value) != expected:
                raise ValueError(f"{field} identity mismatch: {clip['id']}; do not change the suite")
        elif field in values and field not in clip:
            raise ValueError(f"unexpected {field}: {clip['id']}")


def hydrate_references(manifest, reference_root=None, *, fetch=False, cache=None):
    root = Path(reference_root) if reference_root is not None else DEFAULT_ROOT
    contexts = {}
    clips = []
    for frozen in manifest['clips']:
        clip = dict(frozen)
        if 'referenceSha256' in clip:
            # Validate before using the hash as a filename.
            digest = clip['referenceSha256']
            if not re.fullmatch(r'[0-9a-f]{64}', digest):
                raise ValueError(f"invalid reference hash: {clip['id']}")
            source = clip['source']
            if source not in FETCHERS:
                raise ValueError(f'no reference fetcher for {source}')
            path = root / source / (digest + '.json')
            if 'reference' in clip:
                values = {f: clip[f] for f in ('reference', 'lexicalReference') if f in clip}
            elif path.exists():
                values = json.loads(path.read_text(encoding='utf-8'))
            elif fetch:
                sys.path.insert(0, str(ROOT / 'fetchers'))
                from common import Context
                if source not in contexts:
                    contexts[source] = Context(cache or ROOT / '.cache', source)
                adapter = importlib.import_module('sources.' + FETCHERS[source])
                values = adapter.references(contexts[source], clip)
                validate(clip, values)
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = path.with_suffix('.tmp')
                temporary.write_text(json.dumps(values, ensure_ascii=False) + '\n', encoding='utf-8')
                temporary.replace(path)
            else:
                raise ValueError(f"reference missing: {clip['id']}; run fetch.py --references-only --yes first")
            validate(clip, values)
            clip.update({f: values[f] for f in ('reference', 'lexicalReference') if f in values})
        clips.append(clip)
    return {**manifest, 'clips': clips}


def load_manifest(path, reference_root=None):
    return hydrate_references(json.loads(Path(path).read_text(encoding='utf-8')), reference_root)


def receipt_matches(manifest, manifest_sha, scorer_sha, current_manifest_sha, current_scorer_sha):
    """Keep genuine pre-cleanup receipts intact; never relabel their measured hashes."""
    current = (current_manifest_sha, current_scorer_sha)
    published = manifest.get('publishedIdentity', {})
    historical = (published.get('manifestSha256'), published.get('scorerSha256'))
    return (manifest_sha, scorer_sha) == current or (
        all(historical) and (manifest_sha, scorer_sha) == historical)
