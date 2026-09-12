import hashlib
import importlib.util,pathlib,unittest,tempfile,json,types,sys,time
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('worker',pathlib.Path(__file__).parents[1]/'Resources/benchmark_worker.py')
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
class ValidationTests(unittest.TestCase):
 def test_parakeet_signature_and_quantization(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp); (p/'model.safetensors').write_bytes(b'test fixture')
   (p/'config.json').write_text(json.dumps({'target':'nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel','quantization':{'bits':4}}))
   worker.validate_model(p,{'architecture':'parakeet','quantization':'4-bit'})
   with self.assertRaises(ValueError):worker.validate_model(p,{'architecture':'parakeet','quantization':'8-bit'})
 def test_required_normalization_and_remote_code_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);(p/'model.safetensors').write_bytes(b'test fixture');(p/'config.json').write_text('{"model_type":"sensevoice"}')
   entry={'architecture':'sensevoice','quantization':'Unquantized'}
   with self.assertRaisesRegex(ValueError,'normalization'):worker.validate_model(p,entry)
   (p/'am.mvn').write_text('test fixture');worker.validate_model(p,entry)
   (p/'tokenizer_config.json').write_text('{"auto_map":{"AutoTokenizer":"external.code"}}')
   with self.assertRaisesRegex(ValueError,'remote-code'):worker.validate_model(p,entry)
 def test_actual_partial_bytes_and_pinned_download(self):
  with tempfile.TemporaryDirectory() as tmp:
   entry={'id':'test','repository':'fixture/test','revision':'pinned-revision','architecture':'qwen3_asr','quantization':'4-bit'}
   content={'config.json':b'{"model_type":"qwen3_asr","quantization":{"bits":4}}','model.safetensors':b'x'*1024}
   class API:
    def model_info(self,repo,revision,**kwargs):
     assert revision=='pinned-revision'
     return types.SimpleNamespace(siblings=[types.SimpleNamespace(rfilename=k,size=len(v),lfs=None,blob_id=hashlib.sha1(f"blob {len(v)}\0".encode()+v).hexdigest()) for k,v in content.items()])
   def local_paths(folder,name):
    p=pathlib.Path(folder)
    return types.SimpleNamespace(file_path=p/name,metadata_path=p/'.cache'/f'{name}.metadata',incomplete_path=lambda etag:p/'.cache/huggingface/download'/f'{etag}.incomplete')
   def snapshot(repo,revision,local_dir,**kwargs):
    self.assertEqual(revision,'pinned-revision');p=pathlib.Path(local_dir);etag=hashlib.sha1(b'blob 1024\0'+content['model.safetensors']).hexdigest();part=p/'.cache/huggingface/download'/f'{etag}.incomplete';part.parent.mkdir(parents=True)
    part.write_bytes(b'x'*512);part.with_name('stale-revision.incomplete').write_bytes(b'x'*4096);time.sleep(.35)
    for k,v in content.items():(p/k).write_bytes(v)
    part.unlink()
   events=[]
   fake=types.SimpleNamespace(HfApi=API,snapshot_download=snapshot)
   with patch.dict(sys.modules,{'huggingface_hub':fake,'huggingface_hub._local_folder':types.SimpleNamespace(get_local_download_paths=local_paths)}),patch.object(worker,'emit',side_effect=lambda event,**kw:events.append(dict(event=event,**kw))):
    worker.download(types.SimpleNamespace(models_dir=tmp),entry)
   self.assertEqual(events[-1]['event'],'installed')
   self.assertTrue(any(e.get('completed')==512 for e in events))
   self.assertTrue(all(e['completed']<e['total'] for e in events if 'completed' in e))
if __name__=='__main__':unittest.main()
