import importlib.util, pathlib, unittest
spec=importlib.util.spec_from_file_location('worker',pathlib.Path(__file__).parents[1]/'Resources/benchmark_worker.py')
worker=importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)
class ScoringTests(unittest.TestCase):
    def test_normalization(self): self.assertEqual(worker.errors('HELLO, world!', 'hello world'), (0,2))
    def test_edits(self): self.assertEqual(worker.errors('one two three','one four'), (2,3))
    def test_insertions_can_exceed_100_percent(self): self.assertEqual(worker.errors('one','two three four'), (3,1))
    def test_quotation_edges_are_not_words(self): self.assertEqual(worker.errors("Hello world", "'Hello world'"), (0,2))
    def test_internal_apostrophes_preserved(self): self.assertEqual(worker.words("Don't boys'"), ["don't", "boys"])
    def test_empty(self): self.assertEqual(worker.errors('one two',''),(2,2))
if __name__=='__main__': unittest.main()
