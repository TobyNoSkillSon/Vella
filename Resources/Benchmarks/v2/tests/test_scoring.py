"""Synthetic tests: no model inference or network access."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import scoring as s

class ScoringTest(unittest.TestCase):
    def test_turkish_and_diacritics(self):
        self.assertEqual(s.multilingual_tokens('I İ ı i', 'tr'), ['ı','i','ı','i'])
        self.assertEqual(s.multilingual_tokens('I\u0307STANBUL', 'tr'), ['istanbul'])
        self.assertNotEqual(s.multilingual_tokens('ŁÓDŹ', 'pl'),s.multilingual_tokens('LODZ', 'pl'))
        self.assertEqual(s.multilingual_tokens("l’œuvre – co‑op",'fr'),["l'œuvre",'co-op'])

    def test_cjk_width_punctuation_syllables(self):
        self.assertEqual(s.multilingual_tokens('Ｈｅｌｌｏ， 世界！ ２０２６', 'zh'),list('hello世界2026'))
        self.assertEqual(s.multilingual_tokens('가, 나。', 'ko'),['가','나'])
        self.assertNotEqual(s.multilingual_tokens('发','zh'),s.multilingual_tokens('發','zh'))

    def test_fillers(self):
        self.assertEqual(s.english_tokens('Uh- hello, hmm world!'),['hello','world'])
        self.assertEqual(s.english_tokens('uh-oh human album'),['uh','oh','human','album'])
        f=s.fm.score(s.FILLER.sub(' ','Hello uh- world.'), s.FILLER.sub(' ','Hello world.'))
        self.assertEqual(f['characterErrors'],0)
        self.assertEqual(f['referenceCharacters'],len('Hello world.'))

    def test_numbers(self):
        for written,spoken in [('21st','twenty first'),('42%','forty two percent'),('$12.50','twelve dollars and fifty cents'),('1,234','one thousand two hundred thirty four'),('3.05','three point zero five')]:
            with self.subTest(written=written):self.assertEqual(s.english_tokens(written),s.english_tokens(spoken))
        self.assertNotEqual(s.multilingual_tokens('20','pl'),s.multilingual_tokens('dwadzieścia','pl'))

    def test_formatting_filler_rule(self):
        f=s.strip_fillers_formatted
        self.assertEqual(f('I cannot comment on their, uh, specific, uh, situation'),'I cannot comment on their specific situation')
        self.assertEqual(f("Uh, we won't, uh- uh, change it."),"We won't change it.")
        self.assertEqual(f('uh-oh, human error. Um.'),'uh-oh, human error.')
        self.assertEqual(f('He said um.'),'He said.')
        self.assertEqual(f('Wait... what?'),'Wait... what?')

    def test_empty_and_over_hundred(self):
        self.assertEqual(s.alignment(['hello'],[])['deletions'],1)
        a=s.alignment(['hello'],['hello','and','and'])
        self.assertEqual((a['errors'],a['referenceUnits']), (2,1))
        self.assertEqual(s.alignment([],[])['referenceUnits'],0)

    def test_synthetic_track_and_bootstrap(self):
        clips=[dict(id='one',reference='Hello, uh- world.',language='en',tracks=['words','formatting'],allocation='en-a',group='g1',conditions=['noise']),dict(id='two',reference='İSTANBUL 20',language='tr',tracks=['multilingual'],allocation='tr-a',group='g2',conditions=['read']),dict(id='three',reference='안녕!',language='ko',tracks=['multilingual'],allocation='ko-a',group='g3',conditions=['read'])]
        manifest={'id':'synthetic','seed':123,'clips':clips}
        result={'modelID':'m','clips':[{'id':'one','transcript':'hello world.'},{'id':'two','transcript':'istanbul yirmi'},{'id':'three','transcript':'안녕'}]}
        support={'m':['en','tr','ko'],'peer':['en','ko']}
        a=s.score(manifest,result,support,100)
        b=s.score(manifest,result,support,100)
        self.assertEqual(a,b)
        self.assertEqual(a['words']['rate'],0)
        self.assertEqual(a['formatting']['characterErrors'],1)  # 'Hello, uh- world.' -> 'Hello world.'
        self.assertEqual(a['multilingual']['coverage'],'2/9')
        self.assertEqual(a['multilingual']['languages']['tr']['rate'],.5)
        self.assertIsNone(a['multilingual']['languages']['tr']['noReferenceDigits'])
        self.assertEqual(a['multilingual']['languages']['pl']['rate'],None)
        self.assertEqual(a['multilingual']['fixedCohortLanguages'],['ko'])
        self.assertEqual(a['words']['ci95']['independentGroups'],1)
        c=s.compare(a,a,50)
        self.assertEqual(c['words']['difference'],0)
        self.assertEqual(c['languages']['tr']['difference'],0)

if __name__=='__main__':unittest.main()
