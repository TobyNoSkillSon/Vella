# Benchmark methods

Vella 2.0.0. The published cell data is in [Resources/benchmarks.json](../Resources/benchmarks.json). Suite metadata is in [benchmark-method.json](benchmark-method.json). This document describes the measurements, not a prediction for every Mac.

## Suites

Quality uses the full v2 suite. Warm speed, energy and peak worker footprint use the frozen v2-quick subset. The suites are not interchangeable: quick excludes several long-form allocations and is not the source of the published quality figures.

| Suite ID | Clips | Audio min | English min | Formatting min | Manifest SHA-256 |
|---|---:|---:|---:|---:|---|
| vella-v2 | 797 | 239.655 | 166.901 | 50.233 | `361a9b078db7e6813671f719223dfd27c50f54589a1e292239324ac17071e366` |
| vella-v2-quick | 122 | 22.547 | 12.429 | 6.676 | `5cbda7a5f463d4f12bc4e58982ea16e1f23f3f9361aafc42c3344b6d5fd159b8` |

Durations above are calculated from manifest sample counts; the model table rounds suite minutes more coarsely. Both suites use 16000 Hz mono PCM. The manifest hash is SHA-256 of the complete manifest bytes: it pins clip IDs, order, source revisions, references and per-clip file/PCM hashes. The runner verifies SHA-256 of little-endian signed PCM16 bytes before preparing worker inputs.

v2-quick was frozen 2026-09-26 with selection seed 20260926. Selection is seeded shuffle within allocations, then round-robin across speaker/recording groups, with new groups first. It includes a long-form call to exercise segmentation and overlap joining. Excluded allocations: `en-apptek`, `en-earnings22`, `en-earnings25`, `en-rev16`.

| Language | v2 clips | v2 min | v2-quick clips | v2-quick min |
|---|---:|---:|---:|---:|
| de | 47 | 7.257 | 5 | 1.086 |
| en | 366 | 166.901 | 64 | 12.429 |
| es | 31 | 7.508 | 4 | 0.958 |
| fr | 32 | 7.645 | 5 | 1.193 |
| ja | 33 | 7.641 | 4 | 1.083 |
| ko | 56 | 7.586 | 6 | 1.068 |
| pl | 80 | 12.208 | 11 | 1.632 |
| sv | 45 | 7.619 | 6 | 0.991 |
| tr | 42 | 7.696 | 7 | 1.033 |
| zh | 65 | 7.593 | 10 | 1.074 |

Language codes: en English, pl Polish, de German, fr French, es Spanish, sv Swedish, tr Turkish, ja Japanese, zh Mandarin Chinese, ko Korean.

### Dataset identities and licences

These are the source manifest's licence statements, not a grant to redistribute every recording. Sources marked no are not cleared for recording redistribution by this benchmark, whether because terms are restrictive or rights are unclear. No benchmark recording or reference transcript is included here.

| Source ID / dataset | v2 clips / min | Quick clips / min | Licence | Audio redistributable |
|---|---:|---:|---|---|
| `aishell4` — AISHELL-4 test (utterance mirror) | 42 / 3.508 | 7 / 0.468 | CC BY-SA 4.0 | yes |
| `ami` — AMI ES2004a official manual annotations | 5 / 7.813 | 3 / 0.345 | CC BY 4.0 | yes |
| `apptek` — AppTek Call-Center Dialogues | 3 / 22.530 | 0 / 0 | CC BY-SA 4.0 | yes |
| `dipco` — DiPCo S06 eval | 3 / 11.589 | 1 / 0.094 | CDLA-Permissive-1.0 | yes |
| `earnings25` — Earnings25 segmented Q4 2025 | 4 / 24.651 | 0 / 0 | CC BY 4.0 transcripts/metadata; recording redistribution unclear | no |
| `edacc` — EdAcc | 167 / 20.014 | 24 / 2.899 | CC BY-SA 4.0 | yes |
| `fleurs` — FLEURS | 103 / 20.133 | 16 / 3.407 | CC BY 4.0 | yes |
| `hike` — HiKE Korean–English code-switching test | 31 / 3.540 | 3 / 0.469 | Apache-2.0 | yes |
| `klang` — Klang Dialects sv-clean | 45 / 7.619 | 6 / 0.991 | CC BY 4.0 | yes |
| `librispeech-pc` — LibriSpeech-PC test-other | 39 / 5.088 | 10 / 1.489 | CC BY 4.0 | yes |
| `mediaspeech` — MediaSpeech (per-language HF mirror) | 85 / 20.395 | 12 / 2.867 | CC BY 4.0 dataset; original videos retain owners’ copyright | no |
| `mls` — Multilingual LibriSpeech | 12 / 3.046 | 2 / 0.465 | CC BY 4.0 | yes |
| `monsoon` — Monsoon en-IN public test | 104 / 15.075 | 16 / 2.326 | CC BY 4.0 | yes |
| `muscat` — MUSCAT evaluation | 67 / 9.712 | 9 / 1.404 | CC BY 4.0 | yes |
| `notsofar` — NOTSOFAR-1 eval-small with GT | 5 / 14.996 | 2 / 0.090 | CC BY 4.0 | yes |
| `polish-tedx` — Polish TEDx ASR Eval | 48 / 6.044 | 7 / 0.798 | CC BY-NC-ND 4.0 | no |
| `rev-earnings` — Earnings-22/21 Rev verbatim | 5 / 19.900 | 1 / 3.837 | CC BY-SA 4.0 text only; audio rights unclear | no |
| `rev16` — Rev16 verbatim podcast episodes | 4 / 19.955 | 0 / 0 | CC BY-SA 4.0 text only; podcast audio rights unclear | no |
| `zeroth` — Zeroth-Korean official test | 25 / 4.045 | 3 / 0.598 | CC BY 4.0 | yes |

Pinned upstream revisions and attribution:

- `aishell4`: https://www.openslr.org/111/
  - "revision": df062e4993eeb9873605f8c74d6fac1db0560799
  - Licence: https://www.openslr.org/111/
  - Attribution: AISHELL-4, Beijing Shell Shell Technology Co., Ltd.; OpenSLR SLR111; utterance files redistributed by shenyunhang/AISHELL-4.
  - Reference: Human TextGrid meeting annotation; first annotated speaker tier only; silence markup removed.
- `ami`: https://groups.inf.ed.ac.uk/ami/download/
  - "revision": manual-v1.6.2 SHA256:b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d; ES2004a.Array1-01.wav SHA256:6936edac5d0904fc5c4ab175546c5cc5366601fdc1b1e5183a6ea2c10f05d150
  - Licence: https://groups.inf.ed.ac.uk/ami/download/
  - Attribution: AMI Corpus, University of Edinburgh; official AMI download, CC BY 4.0.
  - Reference: AMI manually transcribed orthographic word XML with word timestamps, speaker and original punctuation.
- `apptek`: https://huggingface.co/datasets/apptek-com/apptek_callcenter_dialogues
  - "revision": b98967d9946f7f59f58d08624a2a00fe98fe0219
  - Licence: https://huggingface.co/datasets/apptek-com/apptek_callcenter_dialogues/blob/b98967d9946f7f59f58d08624a2a00fe98fe0219/README.md
  - Attribution: AppTek, Call-Center Dialogues (2026); role-played customer-service recordings.
  - Reference: Manually transcribed verbatim, diarized turn-level references.
- `dipco`: https://huggingface.co/datasets/huckiyang/DiPCo
  - "revision": e2b29d3d0d88692c744feb15e290f7316b68014e
  - Licence: https://huggingface.co/datasets/huckiyang/DiPCo/blob/e2b29d3d0d88692c744feb15e290f7316b68014e/README.md
  - Attribution: DiPCo corpus, Dinner Party Corpus; huckiyang/DiPCo mirror.
  - Reference: Manual close-talk-derived speaker transcripts, timestamped JSON. Inference uses only distant U04 CH1.
- `earnings25`: https://huggingface.co/datasets/florencejiang/earnings25
  - "revision": b4864bf8f0cd1e3b153e502d45bb29cd46993f21
  - Licence: https://arxiv.org/html/2607.23813v1
  - Attribution: Florence Jiang et al., Earnings25 (2026), Zenodo DOI 10.5281/zenodo.18762167.
  - Reference: Existing earnings-call transcripts paired to corporate audio with CTC forced alignment. Original transcriber and human review unreported; NOT Formatting gold.
- `edacc`: https://huggingface.co/datasets/edinburghcstr/edacc
  - "revision": d9ae7bd344f0562b766ec93ee5ce8f2f9568ce66
  - Licence: https://huggingface.co/datasets/edinburghcstr/edacc/blob/d9ae7bd344f0562b766ec93ee5ce8f2f9568ce66/README.md
  - Attribution: University of Edinburgh CSTR, EdAcc (2023).
  - Reference: Professionally transcribed speaker turns with disfluencies and non-speech annotations.
- `fleurs`: https://huggingface.co/datasets/google/fleurs
  - "revision": 70bb2e84b976b7e960aa89f1c648e09c59f894dd
  - Licence: https://huggingface.co/datasets/google/fleurs/blob/70bb2e84b976b7e960aa89f1c648e09c59f894dd/README.md
  - Attribution: Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022), Google.
  - Reference: FLoRes-101 sentences (human-written/translated prose) read aloud; raw_transcription keeps the written case and punctuation.
- `hike`: https://huggingface.co/datasets/thetaone-ai/HiKE
  - "revision": 255609b24005e1fcce3f8b3a452260aaf2872cc9
  - Licence: https://huggingface.co/datasets/thetaone-ai/HiKE/blob/255609b24005e1fcce3f8b3a452260aaf2872cc9/README.md
  - Attribution: HiKE, thetaone-ai; bilingual speakers recorded reviewed, scripted Korean–English sentences.
  - Reference: Published punctuated text and separately supplied lexical text_normalized; no independent spontaneous transcript.
- `klang`: https://huggingface.co/datasets/KlangAI/klang-dialects
  - "revision": 4117db6f1c53f5c1ca03309ce2a8060b96653708
  - Licence: https://huggingface.co/datasets/KlangAI/klang-dialects/blob/4117db6f1c53f5c1ca03309ce2a8060b96653708/LICENSE
  - Attribution: Klang AI, Klang Dialects (2026); opt-in Swedish speakers.
  - Reference: Prompts compared with audio; ASR ensemble/alignment and partial human correction; clean subset excludes ambiguous references.
- `librispeech-pc`: https://www.openslr.org/145/
  - "revision": OpenSLR145 manifests sha256:96d4eae2222b29b66437a21959252419bcd4762e5042e71e023790171054d1c0; openslr/librispeech_asr parquet@2b9f39377850ffce6bf6358257ae9f84b2349497
  - Licence: https://www.openslr.org/resources/145/about.html
  - Attribution: Mehri et al., LibriSpeech-PC; LibriSpeech / OpenSLR 12 audio.
  - Reference: Printed source-book text aligned by researchers to LibriSpeech; text_raw keeps original orthography, text is ASR-normalized.
- `mediaspeech`: https://www.openslr.org/108/
  - "revision": 4008a968760f2187b0c5b2b2db965f1283433059
  - Licence: https://github.com/NTRLab/MediaSpeech
  - Attribution: Kolobov et al., MediaSpeech (2021); original YouTube video owners. HF mirror ymoslem/MediaSpeech.
  - Reference: Two manual annotators and third disagreement resolver; postprocessed lexical sentences. HF mirror strips original video/channel identifiers.
- `mls`: https://huggingface.co/datasets/facebook/multilingual_librispeech
  - "revision": 2e83e61823b4c47dcbcb1980bb88601274127609
  - Licence: https://www.openslr.org/94/
  - Attribution: Pratap et al., MLS (2020); source LibriVox readers and works.
  - Reference: Aligned audiobook text; test transcripts were human-listened and corrected.
- `monsoon`: https://huggingface.co/datasets/VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN
  - "revision": bc1da7b42ef6e2853123c97bf6d22067e4802d11
  - Licence: https://huggingface.co/datasets/VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN/blob/bc1da7b42ef6e2853123c97bf6d22067e4802d11/README.md
  - Attribution: VoiceArena, Monsoon en-IN public test (2026).
  - Reference: ASR drafts corrected and independently checked by native-speaking linguists.
- `muscat`: https://huggingface.co/datasets/goodpiku/muscat-eval
  - "revision": e5e477cc4aeee6b6f5ea65513914b694fb1030f3
  - Licence: https://huggingface.co/datasets/goodpiku/muscat-eval/blob/e5e477cc4aeee6b6f5ea65513914b694fb1030f3/README.md
  - Attribution: MUSCAT authors, bilingual scientific conversations, LREC 2026; native speakers.
  - Reference: Whisper first pass, corrected by speakers; manual segment boundaries and language IDs; one Owl device per spoken event.
- `notsofar`: https://huggingface.co/datasets/microsoft/NOTSOFAR
  - "revision": ba8fd0f034ce185fe4d24f47e53b4b8194795f07
  - Licence: https://huggingface.co/datasets/microsoft/NOTSOFAR/blob/ba8fd0f034ce185fe4d24f47e53b4b8194795f07/LICENSE.txt
  - Attribution: Microsoft, NOTSOFAR-1 dataset; CC BY 4.0.
  - Reference: Speaker-labelled, time-aligned human GT; lexical text is published transcription with non-speech tags removed.
- `polish-tedx`: https://huggingface.co/datasets/s512757/polish-tedx-asr-eval
  - "revision": d0826bb93d2e268dce45b078e0bae56e7d43af21
  - Licence: https://huggingface.co/datasets/s512757/polish-tedx-asr-eval/blob/d0826bb93d2e268dce45b078e0bae56e7d43af21/README.md
  - Attribution: s512757, Polish TEDx ASR Eval (2026); original TEDx Talks speakers/video owners.
  - Reference: Student-transcribed TEDx talks; only rows with verified_by populated have evidenced second-annotator verification. Raw text preserved.
- `rev-earnings`: https://github.com/revdotcom/speech-datasets
  - "revision": c05ab6fd8b4b627d123c922a22a39e993dd37635
  - Licence: https://github.com/revdotcom/speech-datasets/blob/c05ab6fd8b4b627d123c922a22a39e993dd37635/earnings22/LICENSE.md
  - Attribution: Rev, Earnings-22 and Earnings-21 human verbatim transcripts.
  - Reference: Professional Rev verbatim transcription; case, prepunctuation and punctuation are original token columns; aligned timestamps never supply text.
- `rev16`: https://github.com/revdotcom/speech-datasets/tree/c05ab6fd8b4b627d123c922a22a39e993dd37635/rev16
  - "revision": Rev text c05ab6fd8b4b627d123c922a22a39e993dd37635; podcast mirror sanchit-gandhi/rev16_csv@acad9372c439d3d538f846e1c4df9bb9a2730ba1
  - Licence: https://github.com/revdotcom/speech-datasets/blob/c05ab6fd8b4b627d123c922a22a39e993dd37635/rev16/LICENSE.md
  - Attribution: Radford et al. (2023), Rev transcriptionists; underlying podcast creators retain media rights.
  - Reference: Professional human verbatim Rev transcription; case, punctuation and fillers reconstructed solely from nlp token columns. Parakeet used only for cut times, never text.
- `zeroth`: https://www.openslr.org/40/
  - "revision": 1fe937899f828af822293d05e086200946088bdf
  - Licence: https://www.openslr.org/40/
  - Attribution: Zeroth-Korean, OpenSLR SLR40; test-only parquet redistributed by kresnik/zeroth_korean.
  - Reference: Published official read-speech transcript, unpunctuated Korean orthography.

## Scoring

**WER** is English lexical Levenshtein error: total substitutions + deletions + insertions, divided by total reference words, multiplied by 100. Counts are pooled across English clips, not averaged across clip percentages. Reference text is `lexicalReference` when provided, otherwise `reference`. Alignment ties choose substitution, then deletion, then insertion.

**Format** is character error rate against the human-written English formatting subset, multiplied by 100. It is reference agreement, not a universal editorial-correctness score; lower is better. Case and punctuation remain. Both reference and hypothesis undergo the filler preprocessing below, then whitespace collapse and typographic canonicalization: curly double quotes become ASCII double quotes, curly single quotes become apostrophes, en/em dashes become hyphens, and ellipsis becomes three periods. If the reference's double quotes are unbalanced, or an opening quote lacks an opening boundary, double quotes are removed from both sides. Character edit counts and reference character counts are pooled. Auxiliary case/punctuation scores do not replace the published Format CER.

Multilingual scores are separate from English WER. pl/de/fr/es/sv/tr use word tokens; ja/zh/ko use Unicode code points after width normalization, excluding whitespace, punctuation and symbols (CER, not WER). Supported-language coverage comes from the model language map. The scorer keeps separate unweighted supported-language WER and CER means. The gate's multilingual mean is an unweighted diagnostic across supported languages, including mixed units; it is not a pooled English WER.

Normalizer `vella-v2-lexical-1.0.0`; scorer SHA-256 `d917f5ca849a060f380f65acadfeda27022da3d6e2b99bc2115d61439b182eaa`; formatting scorer SHA-256 `965470fad61e1bcb4c6a450e98baa4a7319643a3cfc937d7f2e73894fa13e2e6`.

### Exact preprocessing

This is the scorer's executable preprocessing. It is applied identically to reference and hypothesis. English expands digit forms (including currencies, percentages and ordinals), removes only standalone fillers, keeps contractions, and treats hyphens as word breaks. Multilingual preprocessing does not apply English filler/number rules.

```python
import re
import unicodedata as ud

LANGUAGES = ('pl', 'de', 'fr', 'es', 'sv', 'tr', 'ja', 'zh', 'ko')
CJK = {'ja', 'zh', 'ko'}
FILLERS = {'uh', 'um', 'er', 'ah', 'mm', 'hmm', 'hm', 'erm'}
# A filler is a standalone word, optionally followed by a dangling hyphen (Rev's "uh-").
# Never remove one inside a compound ("uh-oh") or an embedded word ("human").
FILLER = re.compile(r"(?<![\w'-])(?:uh|um|er|ah|mm|hmm|hm|erm)(?:-(?!\w))?(?![\w'-])", re.I)
ONES = ('zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen').split()
TENS = ('', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety')
ORDINAL = {'one':'first','two':'second','three':'third','four':'fourth','five':'fifth','six':'sixth','seven':'seventh','eight':'eighth','nine':'ninth','ten':'tenth','eleven':'eleventh','twelve':'twelfth','twenty':'twentieth','thirty':'thirtieth','forty':'fortieth','fifty':'fiftieth','sixty':'sixtieth','seventy':'seventieth','eighty':'eightieth','ninety':'ninetieth','hundred':'hundredth','thousand':'thousandth','million':'millionth'}
NUMERIC = re.compile(r'(?<!\w)([$£€])?([0-9][0-9,]*(?:\.[0-9]+)?)(st|nd|rd|th)?(%)?(?!\w)', re.I)

def integer_words(n):
    if n < 20: return [ONES[n]]
    if n < 100: return [TENS[n // 10]] + ([ONES[n % 10]] if n % 10 else [])
    if n < 1000: return [ONES[n // 100], 'hundred'] + (integer_words(n % 100) if n % 100 else [])
    for magnitude, name in ((1000000000, 'billion'), (1000000, 'million'), (1000, 'thousand')):
        if n >= magnitude: return integer_words(n // magnitude) + [name] + (integer_words(n % magnitude) if n % magnitude else [])
    raise ValueError('number outside supported range')

def numeric_words(match):
    currency, digits, suffix, percent = match.groups()
    integer, dot, fraction = digits.replace(',', '').partition('.')
    if len(integer) > 12: return match.group()  # retain long IDs, do not imply numeric equivalence
    n = int(integer)
    words = integer_words(n)
    if suffix:
        words[-1] = ORDINAL.get(words[-1], words[-1] + 'th')
    if currency:
        if dot and len(fraction) <= 2:
            words += ['dollar' if n == 1 else 'dollars'] if currency == '$' else ['pound' if n == 1 else 'pounds'] if currency == '£' else ['euro' if n == 1 else 'euros']
            cents = int(fraction.ljust(2, '0'))
            if cents: words += ['and'] + integer_words(cents) + ['cent' if cents == 1 else 'cents']
            dot = ''
        else:
            words += ['dollar' if n == 1 else 'dollars'] if currency == '$' else ['pound' if n == 1 else 'pounds'] if currency == '£' else ['euro' if n == 1 else 'euros']
    if dot: words += ['point'] + [ONES[int(d)] for d in fraction]
    if percent: words += ['percent']
    return ' '.join(words)

FORMAT_FILLER = re.compile(r"(?:,\s*)?(?<![\w'-])(uh|um|er|ah|mm|hmm|hm|erm)(?:-(?!\w))?(?![\w'-])(?:\s*,)?", re.I)

def strip_fillers_formatted(text):
    """Formatting-track filler rule, applied identically to reference and hypothesis.

    Delete a standalone filler together with commas attached to it ("their, uh, specific" ->
    "their specific"); if the filler was capitalised (sentence-initial "Uh, we"), capitalise the
    following word so sentence case survives. Clean dictation output omits fillers.
    """
    out = []; pos = 0
    for m in FORMAT_FILLER.finditer(text):
        out.append(text[pos:m.start()]); pos = m.end()
        if m.group(1)[0].isupper():
            rest = text[pos:]; k = len(rest) - len(rest.lstrip())
            if k < len(rest) and rest[k].isalpha():
                text = text[:pos + k] + rest[k].upper() + rest[k + 1:]
        out.append(' ')
    out.append(text[pos:])
    if pos == 0:
        return text
    cleaned = ' '.join(''.join(out).split())
    cleaned = re.sub(r'([.!?]) +[.!?,;:](?!\.)', r'\1', cleaned)   # "error. Um." -> "error."
    return re.sub(r' +([.!?,;:])(?!\.)', r'\1', cleaned)         # "said um." -> "said."


def english_tokens(text):
    text = ud.normalize('NFC', text).casefold().replace('’', "'")
    text = FILLER.sub(' ', text)
    text = NUMERIC.sub(numeric_words, text)
    # Contractions remain lexical units; hyphens are word breaks (including line-wrap hyphens).
    text = re.sub(r"[^\w\s']|_", ' ', text)
    return [w.strip("'") for w in text.split() if w.strip("'")]

def multilingual_tokens(text, language):
    if language not in LANGUAGES: raise ValueError(f'unknown language {language}')
    text = ud.normalize('NFKC' if language in CJK else 'NFC', text)
    if language == 'tr':
        text = text.replace('I', 'ı').replace('İ', 'i')
        # Unicode decomposed dotted capital I, even if input was canonicalized first.
        text = text.replace('I\u0307', 'i')
    text = text.casefold()
    if language in CJK:
        return [c for c in text if not c.isspace() and ud.category(c)[0] not in 'PS']
    chars=[]
    for i,c in enumerate(text):
        if ud.category(c)[0] in 'PS':
            internal = c in "'’‐‑-" and i > 0 and i+1 < len(text) and text[i-1].isalnum() and text[i+1].isalnum()
            chars.append("'" if internal and c in "'’" else '-' if internal else ' ')
        else: chars.append(c)
    return ''.join(chars).split()
```
After `strip_fillers_formatted` above, Format applies this canonicalization and quote-eligibility rule before character alignment:

```python
import re

TRANSLATION = str.maketrans({'“':'"','”':'"','„':'"','’':"'",'‘':"'",'–':'-','—':'-','…':'...'})

def canonical(text):
    return ' '.join(text.translate(TRANSLATION).split())

def formatted_pair(reference, hypothesis):
    ref=canonical(reference);hyp=canonical(hypothesis)
    # A clipped quotation lacks the context needed to infer its opening/closing mark.
    positions=[i for i,c in enumerate(ref) if c=='"']
    quote_eligible=len(positions)%2==0 and all(i==0 or ref[i-1].isspace() or ref[i-1] in '([{' for i in positions[::2])
    if not quote_eligible:ref=canonical(ref.replace('"',''));hyp=canonical(hyp.replace('"',''))
    return ref, hyp
```


## Warm speed and segmentation

Speed (RTFx) = original audio seconds / warm-pass wall seconds. The model is loaded and a first request is run before the timed pass. The numerator does not count duplicated overlap or synthetic streaming gaps.

Inside the timer: the sequential worker request loop, stdio/JSON transport, worker reading the prepared segment WAVs, feature extraction, inference/decoding, reply handling, overlap assembly and per-clip cache reads. This is a worker benchmark using the app's segmentation policy, not a kernel-only timer. Outside: original file decode/resampling, preparation of segmented PCM/WAV inputs, model load/first-request warm-up, and the app/HTTP layer. `vella transcribe` end-to-end additionally includes decoding the file and app/HTTP work, so its wall time is not the catalog's speed denominator.

Dictation follows `SegmentedPCMWriter` and `RecordingSession` semantics: silence-aware cuts, forced-cut overlap, final-tail merge/re-split and conservative text overlap removal. Whisper uses a longer preferred window than other dictation architectures. The Python port differs only in code-point versus Swift grapheme-cluster counting for the overlap text window, and last-bit RMS summation order; it is not the app process itself.

Streaming clips are concatenated into a persistent session, with a 1.20 s digital-silence endpoint gap between clips, then finished. Requests send 1600-sample PCM packets faster than real time. Its timer includes packet encoding, gaps and final commit; it does not measure microphone-to-visible-text latency. Streaming state can make transcripts depend on clip order and shard boundaries. Identity checks must replay the same preceding stream and shards.

Segmentation `app-vsseg-seg2`:

| Policy | Preferred s | Maximum s | Silence s / RMS | Overlap s | Minimum tail s | Merge slack s |
|---|---:|---:|---|---:|---:|---:|
| default | 5.00 | 25.00 | 0.40 / 0.003 | 0.50 | 2.00 | 2.00 |
| whisper | 20.00 | 25.00 | 0.40 / 0.003 | 0.50 | 2.00 | 2.00 |


## Energy and memory

VellaEnergy reads cumulative macOS IOReport Energy Model counters at bracket start and end: there is **no fixed energy sampling interval**. The components are CPU + GPU + ANE + DRAM, system-wide, not attributed to the worker and not wall-socket power. Unavailable channels yield no figure rather than zero.

Each fresh-worker run records cold load/warm-up separately, then a 10000 ms loaded-idle baseline, then a warm workload bracket. For each component: `net joules = work joules − loaded-idle joules × (work seconds / idle seconds)`; negative differences are retained. Sum the four components and divide by original audio minutes for J / min. The energy bracket ends after child exit/teardown, slightly beyond the speed timer. The 1000 ms dictation-idle polling is a precondition check, not energy sampling.

There are 3 repeats per cell. Slow workloads are sharded into bounded brackets (270 s limit); each shard has its own loaded-idle subtraction. A repeat merges shard joules and audio durations, and sums warm wall times before calculating speed. Published speed is the median repeat speed; energy is the median clean-repeat J / min. The aggregator requires at least two clean repeats for energy, otherwise it publishes no energy figure; each cell's `energy_note` records the clean count and range. Peak RAM is the maximum worker `proc_pid_rusage` peak footprint across repeats, including loading, reported in MiB despite the table's MB label. It is not total app or system RAM.

CPU-only work takes a shared quiet lock. GPU correctness work adds an exclusive GPU lock; its timings are not catalog measurements. Measurement takes the exclusive quiet lock plus GPU lock, so managed builds/tests and inference do not overlap. The wrapper also waits for idle dictation and checks foreign CPU/GPU activity before beginning. Steady display/terminal compositing is recorded separately and covered by the idle subtraction; excessive compositing prevents a start. These locks do not stop unrelated user work.

Within a bracket, the absolute change in foreign CPU use between loaded-idle and work must be at most 0.50 cores, after subtracting the change in `kernel_task` GPU-driver CPU work when readable. Dictation observed during the preconditions or idle baseline fails the idle guard; this polling is not a continuous guard inside the warm workload. Contaminated brackets are not published; the driver quarantines unfinished evidence and retries up to 6 total attempts, then blocks. The contamination check is a proxy, not proof that all background energy is eliminated.

## Build and hardware identity

Measured hardware: Apple M5 Max, macOS 26.6, 40 GPU cores. Measurement dates: 2026-10-01, 2026-10-02. Measured build `53d1bf3`, built from `932136f`; worker SHA-256 `8a215e827e5972ef9afb4db7cf57ea8f068006f40ef1510ccd66e6977546b99d`. Frozen lever-map SHA-256 `f6b6918a5ede08b3dffa45f4540bc9c9c488f566da8ef63fd7860e0aa8723242`.

Authoritative shipped source identities:

- Packages Git tree: `6851d8c101f507aea8980af93fd877aa0e84a20c`.
- Worker Git tree: `7640d1d1e0953f58d894ee89711a2f0f74ab7083`.
- Build-script SHA-256: `1862cec695156417ab3518e58b95ab61f491f8c59e867c4709ee68c9024dfc90`.
- CI worker SHA-256: pending verified publication artifact; no local binary is substituted.

Commit IDs identify published history; tree and byte hashes pin content even if history is rewritten. Model checkpoint revisions and derived-quantization recipes are pinned in [models.json](../Resources/models.json) and each benchmark cell's `recipe`.

Shipped-source scope: Worker/Packages tree hashes and build-script bytes are authoritative. The informational commit identifies the measured-defaults baseline, not this chip-safety delta: SmallMGEMM now requires macOS 26.2 for tensor ops; FastPathGate keys and verdict metadata now include GPU architecture and device name; Parakeet tensor wrappers guard availability; worker key/capability tests and the shared GateRecord codec were updated. Kernels, tile plans, deadlines, dependency pins and pinned build scripts are unchanged. Measurements and the original bridge below remain dated evidence from before this safety delta, not a new performance or verdict-reuse qualification. Old verdict keys miss and each model/recipe self-tests once on its next optimized load. Worker SHA256 is filled only from the verified CI artifact at publish, never a local candidate.

Carried-over measurements use a scoped **CPU-only identity bridge**, not a fresh performance run: Historical, before GPU-identity keys: scoped source bridge: 83 protected paths, with 3 comment-only hunks allowed; separate source diff confirms Nemotron; gate keys 24/24 identical; measured-worker verdicts 24/24 match. Builds are not bit-reproducible; metallib identical. No cross-build speed/energy spot remeasurement was performed for this bridge. Source/key/verdict equality is evidence about executed code, not evidence that binary bytes are identical. Clean Swift rebuilds differ even under the same compiler; the Metal library is byte-identical.

Recorded Whisper Fast identity receipt: One gpulock run of the new 4d5e996 build: large-v3 and turbo × FP16/8b/4b, each 122/122 clips token-identical to measured Fast transcripts.

Clean rebuild receipt: Swift driver/compiler `1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`; `Apple metal version 32023.921 (metalfe-32023.921.6)`; `Xcode 27.0`; macOS build `25G72`. This is the rebuild receipt, not a per-bracket OS-build capture. Identical `default.metallib` SHA-256: `b3bb7c969e967732920d798aee2c98fb8ee0f75419d667dfd22fb9845ad144ef`.

| Model | Recorded recipe gate revisions |
|---|---|
| Nemotron 3.5 Streaming | `native-kernels-10`, `stock` |
| Parakeet v3 | `native-kernels-10`, `stock` |
| Parakeet v3 Ultra | `native-kernels-10`, `stock` |
| Qwen3 ASR 0.6B | `native-kernels-10`, `stock` |
| Qwen3 ASR 1.7B | `native-kernels-10`, `stock` |
| Whisper large-v3 | `stock`, `whisper-4` |
| Whisper large-v3 turbo | `stock`, `whisper-4` |

Refreshed same-build cells: source `7ccd67c790bb52ec15c344474ee0dc6872e7d0a4`, worker SHA-256 `b49faa52236c39ab210c3a11d993b396517b8483a1859953acccdd7af68bf119`. Per-cell `measured` and `build_provenance` fields identify their own date and build; older figures do not silently acquire the refresh date.

## Modes and gates

**Standard** runs no kept optimization levers. **Optimized Exact** runs exact kept levers only. **Optimized Fast** runs every kept lever, including inexact ones. Kept levers ship on by default in their mode; benchmark environment switches are A/B controls, not user setup requirements. Exact components match the stock path on the load-time self-test, not a universal transcript-identity guarantee. Identical recipes can share a canonical measured cell through `display_cells`; separate recipes or missing measurements must not borrow a sibling's figure.

The load-time hardware/component self-test, tier **presence** gate and task-quality gate are different checks. Presence decides whether a tier is offered at all. The tighter task-quality gate (historically called the recommendation gate) records whether loss exceeds the measured noise allowance; Vella does not automatically recommend a tier.

Presence fails for request errors/worker exits, an empty or truncated clip beyond the recorded lost-clip allowance, English or supported-language mean degradation at or above +5.00 percentage points, or any supported language at or above +10.00 points. Lost clips are empty hypotheses or deleted reference tails containing at least 3 units the baseline had correct. CJK uses character units. Middle-clip deletion spans and total deletion counts are reported, not independently gated.

For English WER and Format CER, tolerance = `min(0.20, max(0.10, English noise + 0.05))` points. For the supported-language mean, tolerance = `min(0.30, max(0.10, multilingual noise + 0.05))`. Each supported language with at least 5.00 minutes must not degrade by more than +2.00 points. Errors and lost clips are also checked. The historical streaming trade policy permits a multilingual-only failure when English and the other checks pass and speed is at least 1.25× the fastest outright-passing tier; it is not a relaxation of the presence gate. The final per-cell runner calls the strict comparator directly and does not apply that historical override.

Dated noise pairs are reused, not rerun on the final build. A pair is a measured rate difference, not a confidence interval or a three-seed loss calibration. Missing pairs use the absolute tolerance floor and are not claimed to have zero measured noise.

| Model | Noise pair date | English noise pt | ML noise pt | English / Format limit pt | ML mean limit pt |
|---|---|---:|---:|---:|---:|
| Nemotron 3.5 Streaming | no pair | not measured | not measured | 0.10 | 0.10 |
| Parakeet v3 | 2026-09-28 | 0.04 | 0.15 | 0.10 | 0.20 |
| Parakeet v3 Ultra | 2026-09-28 | 0.02 | 0.00 | 0.10 | 0.10 |
| Qwen3 ASR 0.6B | 2026-09-28 | 0.00 | 0.00 | 0.10 | 0.10 |
| Qwen3 ASR 1.7B | 2026-09-28 | 0.00 | 0.00 | 0.10 | 0.10 |
| Whisper large-v3 | no pair | not measured | not measured | 0.10 | 0.10 |
| Whisper large-v3 turbo | 2026-09-28 | 0.02 | 0.17 | 0.10 | 0.22 |

Pair identities:

- Nemotron 3.5 Streaming: no noise pair measured; floor tolerances.
- Parakeet v3: per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:v2.
- Parakeet v3 Ultra: per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:v2.
- Qwen3 ASR 0.6B: per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:r8-v2.
- Qwen3 ASR 1.7B: per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:r8-v2.
- Whisper large-v3: no noise pair measured; floor tolerances.
- Whisper large-v3 turbo: per-family noise pair of 2026-09-28: FP16:seed-0x5eed-v2 vs FP16:seed-0x0b0e-v2.

Gate baselines are retained in the data, not inferred from the mode name. For the original non-Whisper measurements, per-cell gates compare with tier-16 Standard of the same measured build. Retained original Whisper Fast cell gates used the withdrawn Float32 Standard baseline; the original Whisper tier quality/presence verdicts compare with measured Optimized Fast fp16, not shipped fp16 Standard. A same-build refresh records its changed baseline explicitly.

## Not measured yet

No offered cells currently have missing measurement status. Per-cell dates/builds still apply.

The original Whisper loader made a Float32 positional table that promoted activations away from checkpoint dtype. The shipped loader fixes this and removes the encoder-dtype lever. Earlier Standard/Exact figures were withdrawn rather than relabeled as faithful fp16 measurements. Fast's identity receipt supports its carry-over only; it does not create Standard/Exact speed or energy measurements. Unoffered tiers are a gate decision, not missing measurements.

## Check your Mac

Run `vella diagnose` while Vella is idle with a dictation model loaded; `vella diagnose --json` returns structured data. It never starts the app or downloads a model. `--load` explicitly loads the selected dictation model first. It reports hardware, OS/app/worker versions, selected mode, active components and fallbacks.

For each loaded dictation model it runs five built-in public clips: one warm-up pass, whose transcripts are compared, then three sequential timed passes. Local speed is total clip audio seconds divided by median pass time. The timing uses the app's HTTP API and includes file decode and transport, unlike the catalog worker timer. Transcript comparison is whitespace-token edit distance with case/punctuation kept, **not** the v2 normalizer or WER against dataset gold. It compares with the qualified reference for that model, precision and effective mode only; missing/unqualified references are not replaced. Streaming models are reported but not timed by this API diagnostic.

Different Macs and fallback components can change speed and text. Reference speed remains an M5 Max measurement, never an estimate for your Mac, and diagnose does not measure energy. A short five-clip diagnostic is not a full-suite quality gate. A provisional bundled reference is labeled as provisional rather than qualified release evidence.

## Reproduction and drift checks

`xcrun swift scripts/benchmark-method.swift --check` regenerates this document from the portable suite snapshot and published benchmark data and fails if it differs. Release checks run it alongside the other documentation checks. The private finalization step also verifies the snapshot against the source manifests/scorer and runs this check. The snapshot is repository documentation, not an app resource.

The measurement runner itself will be published with 2.1 after cleanup. In 2.0 this is a methods description with pinned dataset identities, scoring rules and measured cell provenance, not a claim that the complete runner and source manifests are already public. No universal Apple Silicon speed/energy result, bit-reproducible Swift binary, or full-suite OS build identifier is asserted beyond the recorded evidence.
