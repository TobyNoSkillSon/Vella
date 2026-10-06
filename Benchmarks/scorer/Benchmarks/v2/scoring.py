#!/usr/bin/env python3
"""Pinned, model-independent v2 scoring. No model runtime or third-party dependencies."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import random
import re
import sys
import unicodedata as ud

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import formatting_metrics as fm  # v1 canonicalisation and punctuation/case alignment, read-only
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from references import hydrate_references

NORMALIZER_VERSION = 'vella-v2-lexical-1.0.0'
SCORER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
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

def alignment(a, b):
    """Return substitutions/deletions/insertions, with deterministic tie order S,D,I."""
    previous = [(i, 0, 0, i) for i in range(len(b)+1)]
    for x in a:
        row = [(previous[0][0]+1, previous[0][1], previous[0][2]+1, previous[0][3])]
        for j,y in enumerate(b,1):
            substitute = (previous[j-1][0]+(x != y), previous[j-1][1]+(x != y), previous[j-1][2], previous[j-1][3])
            delete = (previous[j][0]+1, previous[j][1], previous[j][2]+1, previous[j][3])
            insert = (row[-1][0]+1, row[-1][1], row[-1][2], row[-1][3]+1)
            row.append(min((substitute,delete,insert), key=lambda z:z[0]))
        previous=row
    _,s,d,i=previous[-1]
    return {'substitutions':s,'deletions':d,'insertions':i,'errors':s+d+i,'referenceUnits':len(a)}

def counts(rows, field):
    n=sum(x[field]['referenceUnits'] for x in rows)
    e=sum(x[field]['errors'] for x in rows)
    return {'errors':e,'referenceUnits':n,'rate':e/n if n else None,'clips':len(rows)}

def formatting_counts(rows):
    if not rows:return None
    out=fm.aggregate([x['formatting'] for x in rows])
    out['rate']=out['formattedCharacterErrorRate']
    return out

def percentile(values, p):
    values.sort(); pos=(len(values)-1)*p; low=int(pos)
    return values[low]+(values[min(low+1,len(values)-1)]-values[low])*(pos-low)

def bootstrap(rows, metric, iterations=10000, seed=20260924):
    """Allocation-stratified group resampling; same draws for every metric/model with same manifest."""
    if not rows or iterations <= 0:return None
    strata=defaultdict(lambda:defaultdict(list))
    for row in rows: strata[row['allocation']][row['group']].append(row)
    rng=random.Random(seed); values=[]
    for _ in range(iterations):
        sampled=[]
        for alloc in sorted(strata):
            groups=strata[alloc]; keys=sorted(groups)
            for __ in keys: sampled.extend(groups[keys[rng.randrange(len(keys))]])
        value=metric(sampled)
        if value is not None:values.append(value)
    return {'lower':percentile(values,.025),'upper':percentile(values,.975),'iterations':len(values),'seed':seed,'independentGroups':sum(len(v) for v in strata.values())} if values else None

def _ci(rows, field, iterations, seed):
    return bootstrap(rows, lambda sampled: counts(sampled,field)['rate'], iterations, seed)

def score(manifest, result, support=None, iterations=10000):
    manifest=hydrate_references(manifest)
    clips=manifest['clips']; outcomes=result['clips']
    by_id={x['id']:x for x in clips}
    if len(by_id)!=len(clips):raise ValueError('duplicate manifest ids')
    predictions={x['id']:x for x in outcomes}
    if len(predictions)!=len(outcomes) or set(predictions)!=set(by_id):raise ValueError('result/manifest clip IDs do not match exactly')
    if result.get('suiteID') and result['suiteID']!=manifest['id']:raise ValueError('suite ID mismatch')
    rows=[]
    for clip in clips:
        pred=predictions[clip['id']]; language=clip.get('language','en'); tracks=clip.get('tracks',['words','formatting'] if language=='en' else ['multilingual'])
        if language=='en' and 'words' not in tracks and 'formatting' not in tracks:raise ValueError('English clip with no English track')
        row={k:clip.get(k) for k in ('id','language','allocation','group','conditions','referenceType','duration')}
        row['language']=language;row['allocation']=row['allocation'] or 'legacy-v1';row['group']=str(row['group'] or clip.get('speaker') or row['id']);row['conditions']=row['conditions'] or []
        row['tracks']=tracks; row['hasReferenceDigits']=any(c.isdigit() for c in clip['reference'])
        text=pred['transcript']
        if 'words' in tracks:row['words']=alignment(english_tokens(clip.get('lexicalReference',clip['reference'])),english_tokens(text))
        if 'formatting' in tracks:
            row['formatting']=fm.score(strip_fillers_formatted(clip['reference']),strip_fillers_formatted(text))
        if 'multilingual' in tracks:
            if language not in LANGUAGES:raise ValueError('invalid multilingual language')
            tokens=multilingual_tokens(clip.get('lexicalReference',clip['reference']),language)
            row['multilingual']=alignment(tokens,multilingual_tokens(text,language))
            row['multilingual']['unit']='codepoint' if language in CJK else 'word'
            row['multilingual']['numbersSensitive']=row['hasReferenceDigits']
        rows.append(row)
    seed=manifest.get('seed',20260924)
    output={'schemaVersion':2,'scoringVersion':NORMALIZER_VERSION,'scorerSHA256':SCORER_SHA256,'modelID':result.get('modelID'),'suiteID':manifest['id'],'clips':rows}
    for track in ('words','formatting'):
        subset=[r for r in rows if track in r['tracks']]
        if track=='words':
            metric=lambda rs:counts(rs,track)['rate']; score_data=counts(subset,track) if subset else None
        else:
            metric=lambda rs:formatting_counts(rs)['rate'];score_data=formatting_counts(subset)
        if score_data is not None:
            score_data['ci95']=bootstrap(subset,metric,iterations,seed)
            aggregate=lambda rs:counts(rs,track) if track=='words' else formatting_counts(rs)
            score_data['allocations']={a:dict(aggregate([r for r in subset if r['allocation']==a]),ci95=bootstrap([r for r in subset if r['allocation']==a],metric,iterations,seed)) for a in sorted({r['allocation'] for r in subset})}
            score_data['conditions']={c:dict(aggregate([r for r in subset if c in r['conditions']]),ci95=bootstrap([r for r in subset if c in r['conditions']],metric,iterations,seed)) for c in sorted({c for r in subset for c in r['conditions']})}
        output[track]=score_data
    support=support or {}; known=output['modelID'] in support
    eligible=set(support.get(output['modelID'],[])) if known else set()
    cohort=set.intersection(*(set(langs) for langs in support.values())) & set(LANGUAGES) if support else set()
    multi={}; subset=[r for r in rows if 'multilingual' in r['tracks']]
    for lang in LANGUAGES:
        language_rows=[r for r in subset if r['language']==lang]
        if not language_rows:
            multi[lang]={'status':'missing-clips','rate':None};continue
        # Rates are always computed as diagnostics; only supported languages enter macros/rankings.
        score_data=counts(language_rows,'multilingual');score_data['unit']='CER' if lang in CJK else 'WER'
        score_data['status']='supported' if lang in eligible else 'unsupported' if known else 'support-unknown'
        score_data['ci95']=_ci(language_rows,'multilingual',iterations,seed)
        no_digits=[r for r in language_rows if not r['hasReferenceDigits']]
        score_data['noReferenceDigits']=dict(counts(no_digits,'multilingual'),ci95=_ci(no_digits,'multilingual',iterations,seed)) if no_digits else None
        score_data['allocations']={a:dict(counts([r for r in language_rows if r['allocation']==a],'multilingual'),ci95=_ci([r for r in language_rows if r['allocation']==a],'multilingual',iterations,seed)) for a in sorted({r['allocation'] for r in language_rows})}
        score_data['conditions']={c:dict(counts([r for r in language_rows if c in r['conditions']],'multilingual'),ci95=_ci([r for r in language_rows if c in r['conditions']],'multilingual',iterations,seed)) for c in sorted({c for r in language_rows for c in r['conditions']})}
        multi[lang]=score_data
    available=[l for l in LANGUAGES if multi[l].get('status')=='supported']
    def macro(languages):
        # Mixed-unit diagnostic only: publish separate WER and CER macros as headline.
        languages=[l for l in languages if multi[l].get('status')=='supported']
        if not languages:return None
        def evaluate(sample):
            rates=[counts([r for r in sample if r['language']==l],'multilingual')['rate'] for l in languages]
            return sum(rates)/len(rates) if all(x is not None for x in rates) else None
        chosen=[r for r in subset if r['language'] in languages]
        return {'languages':languages,'rate':sum(multi[l]['rate'] for l in languages)/len(languages),'ci95':bootstrap(chosen,evaluate,iterations,seed)}
    output['multilingual']={'languages':multi,'coverage':f'{len(available)}/9','supportKnown':known,'macroWER':macro([l for l in available if l not in CJK]),'macroCER':macro([l for l in available if l in CJK]),'fixedCohortLanguages':sorted(cohort),'fixedCohortWER':macro([l for l in sorted(cohort) if l not in CJK]) if cohort <= set(available) else None,'fixedCohortCER':macro([l for l in sorted(cohort) if l in CJK]) if cohort <= set(available) else None}
    return output

def compare(a, b, iterations=10000, seed=20260924):
    """Paired cluster-bootstrap difference (a - b) between two v2 score outputs on the same manifest."""
    if a['suiteID']!=b['suiteID'] or [r['id'] for r in a['clips']]!=[r['id'] for r in b['clips']]:
        raise ValueError('scores are not from the same suite/clip list')
    pairs=[dict(ra,other=rb) for ra,rb in zip(a['clips'],b['clips'])]
    def diff(rows,field,subset):
        def rate(rs,side):
            use=[r if side=='a' else r['other'] for r in rs]
            if field=='formatting': return formatting_counts(use)['rate'] if use else None
            return counts(use,field)['rate']
        def metric(rs):
            x,y=rate(rs,'a'),rate(rs,'b')
            return None if x is None or y is None else x-y
        chosen=[r for r in rows if subset(r)]
        if not chosen: return None
        return {'difference':metric(chosen),'ci95':bootstrap(chosen,metric,iterations,seed)}
    out={'a':a.get('modelID'),'b':b.get('modelID'),'suiteID':a['suiteID'],
         'words':diff(pairs,'words',lambda r:'words' in r['tracks']),
         'formatting':diff(pairs,'formatting',lambda r:'formatting' in r['tracks']),'languages':{}}
    for lang in LANGUAGES:
        out['languages'][lang]=diff(pairs,'multilingual',lambda r,l=lang:'multilingual' in r['tracks'] and r['language']==l)
    return out

def main():
    if len(sys.argv)>1 and sys.argv[1]=='compare':
        parser=argparse.ArgumentParser(description='Paired difference between two v2 score files (a - b).')
        parser.add_argument('command');parser.add_argument('a');parser.add_argument('b');parser.add_argument('--bootstrap',type=int,default=10000)
        args=parser.parse_args()
        print(json.dumps(compare(json.loads(Path(args.a).read_text()),json.loads(Path(args.b).read_text()),args.bootstrap),indent=2));return
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest');parser.add_argument('result');parser.add_argument('--support');parser.add_argument('--bootstrap',type=int,default=10000);parser.add_argument('--output');parser.add_argument('--references-root',type=Path)
    args=parser.parse_args()
    if args.bootstrap<0:parser.error('bootstrap must be nonnegative')
    manifest_path=Path(args.manifest);result_path=Path(args.result)
    manifest=json.loads(manifest_path.read_text());result=json.loads(result_path.read_text())
    if result.get('suiteHash') and result['suiteHash'] not in (hashlib.sha256(manifest_path.read_bytes()).hexdigest(),manifest.get('publishedIdentity',{}).get('manifestSha256')):raise ValueError('suite hash mismatch')
    manifest=hydrate_references(manifest,args.references_root)
    support=json.loads(Path(args.support).read_text()) if args.support else None
    data=score(manifest,result,support,args.bootstrap)
    path=Path(args.output) if args.output else result_path.with_name(result_path.stem+'.v2.json')
    if path.resolve()==result_path.resolve():raise ValueError('refusing to overwrite inference result')
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(data,ensure_ascii=False))

if __name__=='__main__':main()
