"""Formatting agreement with an explicit reference, not unique editorial correctness."""
import re, hashlib, pathlib
from collections import Counter

SCORING_VERSION = 'formatted-v1'
SCORER_SHA256 = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
TRANSLATION = str.maketrans({'“':'"','”':'"','„':'"','’':"'",'‘':"'",'–':'-','—':'-','…':'...'})
WORD = re.compile(r"\w+(?:'\w+)*")
TOKEN = re.compile(r"\w+(?:'\w+)*|\.{3}|[^\w\s]")

def canonical(text):
    return ' '.join(text.translate(TRANSLATION).split())

def distance(a, b):
    row = list(range(len(b)+1))
    for i,x in enumerate(a,1):
        new=[i]
        for j,y in enumerate(b,1):new.append(min(new[-1]+1,row[j]+1,row[j-1]+(x!=y)))
        row=new
    return row[-1]

def parts(text):
    words=[]; gaps=[Counter()]
    for token in TOKEN.findall(text):
        if WORD.fullmatch(token): words.append(token);gaps.append(Counter())
        else:gaps[-1][token]+=1
    return words,gaps

def matched_words(reference, hypothesis):
    a=[x.lower() for x in reference];b=[x.lower() for x in hypothesis]
    matrix=[list(range(len(b)+1))]
    for i,x in enumerate(a,1):
        row=[i]
        for j,y in enumerate(b,1):row.append(min(row[-1]+1,matrix[-1][j]+1,matrix[-1][j-1]+(x!=y)))
        matrix.append(row)
    pairs={};i=len(a);j=len(b)
    while i or j:
        if i and j and matrix[i][j]==matrix[i-1][j-1]+(a[i-1]!=b[j-1]):
            if a[i-1]==b[j-1]:pairs[i-1]=j-1
            i-=1;j-=1
        elif i and matrix[i][j]==matrix[i-1][j]+1:i-=1
        else:j-=1
    return pairs

def score(reference, hypothesis):
    ref=canonical(reference);hyp=canonical(hypothesis)
    # A clipped quotation lacks the context needed to infer its opening/closing mark.
    positions=[i for i,c in enumerate(ref) if c=='"']
    quote_eligible=len(positions)%2==0 and all(i==0 or ref[i-1].isspace() or ref[i-1] in '([{' for i in positions[::2])
    if not quote_eligible:ref=canonical(ref.replace('"',''));hyp=canonical(hyp.replace('"',''))
    rw,rg=parts(ref);hw,hg=parts(hyp);pairs=matched_words(rw,hw)
    counts=dict(characterErrors=distance(ref,hyp),referenceCharacters=len(ref),
        caseCorrect=sum(rw[i]==hw[j] for i,j in pairs.items()),caseTotal=len(pairs),referenceWordCount=len(rw),eligibleReferencePunctuation=0,
        punctuationTP=0,punctuationFP=0,punctuationFN=0,quoteTP=0,quoteFP=0,quoteFN=0,
        eligibleBoundaries=0,referenceBoundaries=len(rg),referencePunctuation=sum(sum(g.values()) for g in rg),
        quoteEligible=quote_eligible,quotedReference=quote_eligible and '"' in ref)
    for gap in range(len(rg)):
        if gap==0:target=0 if pairs.get(0)==0 else None
        elif gap==len(rw):target=len(hw) if pairs.get(gap-1)==len(hw)-1 else None
        else:
            left=pairs.get(gap-1);right=pairs.get(gap)
            target=right if left is not None and right==left+1 else None
        if target is None:continue
        a,b=rg[gap],hg[target];counts['eligibleBoundaries']+=1;counts['eligibleReferencePunctuation']+=sum(a.values())
        counts['punctuationTP']+=sum((a&b).values());counts['punctuationFP']+=sum((b-a).values());counts['punctuationFN']+=sum((a-b).values())
        if quote_eligible:
            counts['quoteTP']+=min(a['"'],b['"']);counts['quoteFP']+=max(0,b['"']-a['"']);counts['quoteFN']+=max(0,a['"']-b['"'])
    return counts

def aggregate(clips):
    keys=('referenceWordCount','eligibleReferencePunctuation','characterErrors','referenceCharacters','caseCorrect','caseTotal','punctuationTP','punctuationFP','punctuationFN','quoteTP','quoteFP','quoteFN','eligibleBoundaries','referenceBoundaries','referencePunctuation')
    result={k:sum(c[k] for c in clips) for k in keys}
    def f1(prefix):
        denominator=2*result[prefix+'TP']+result[prefix+'FP']+result[prefix+'FN']
        return 2*result[prefix+'TP']/denominator if denominator else None
    result.update(scoringVersion=SCORING_VERSION,scorerSHA256=SCORER_SHA256,matchedWordCoverage=result['caseTotal']/max(1,result['referenceWordCount']),boundaryCoverage=result['eligibleBoundaries']/max(1,result['referenceBoundaries']),punctuationCoverage=result['eligibleReferencePunctuation']/max(1,result['referencePunctuation']),formattedCharacterErrorRate=result['characterErrors']/max(1,result['referenceCharacters']),
        capitalizationAccuracy=result['caseCorrect']/result['caseTotal'] if result['caseTotal'] else None,
        punctuationF1=f1('punctuation'),quotationF1=f1('quote'),quotedReferenceClips=sum(c['quotedReference'] for c in clips),
        quoteEligibleClips=sum(c['quoteEligible'] for c in clips))
    return result
