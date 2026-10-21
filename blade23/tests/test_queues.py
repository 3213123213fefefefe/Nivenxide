import concurrent.futures
import importlib.util
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request,urlopen

spec=importlib.util.spec_from_file_location('relay',str(Path(__file__).resolve().parents[1]/'blade23_server.py'))
relay=importlib.util.module_from_spec(spec);spec.loader.exec_module(relay)

class RelayTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.db=str(Path(self.tmp.name)/'state.db')
  self.token='test-key-only-not-for-users-123456'
  self.server=relay.make_server('127.0.0.1',0,self.token,self.db)
  self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
  self.base='http://127.0.0.1:'+str(self.server.server_port)
 def tearDown(self):
  self.server.shutdown();self.server.server_close();self.server.store.close();self.thread.join();self.tmp.cleanup()
 def call(self,method,path,data=None,authorized=True):
  headers={'Content-Type':'application/json'}
  if authorized:headers['Authorization']='Bearer '+self.token
  req=Request(self.base+path,data=json.dumps(data).encode() if data else None,headers=headers,method=method)
  with urlopen(req,timeout=3) as r:return json.load(r)
 def put(self,i,joined=1):
  return self.call('POST','/v1/item',{'key':f'sentinel/.cache/rot_receiver_queue/{i}.json','value':{'userId':i,'joined':joined,'at':-999,'jobId':'same-server','state':'waiting','progress':0}})['value']
 def test_auth_and_namespace(self):
  with self.assertRaises(HTTPError) as e:self.call('GET','/v1/health',authorized=False)
  self.assertEqual(e.exception.code,401)
  self.assertEqual(self.call('GET','/v1/health')['service'],'blade23')
  with self.assertRaises(HTTPError) as e:self.call('POST','/v1/item',{'key':'../../secret.json','value':{}})
  self.assertEqual(e.exception.code,400)
 def test_two_pcs_server_order_time_and_handoff(self):
  first=self.put(11,joined=9999999999999) # PC1 clock ahead
  second=self.put(22,joined=-99999999999) # PC2 clock behind
  self.assertLess(first['_order'],second['_order'])
  self.assertLess(abs(first['at']-time.time()),2)
  again=self.put(11,joined=9999999999999)
  self.assertEqual(first['_order'],again['_order'])
  entries=self.call('GET','/v1/list?prefix=sentinel/.cache/rot_receiver_queue')['entries']
  self.assertEqual(len(entries),2)
  value=again.copy();value['state']='done';value['progress']=16
  self.call('POST','/v1/item',{'key':'sentinel/.cache/rot_receiver_queue/11.json','value':value})
  entries=self.call('GET','/v1/list?prefix=sentinel/.cache/rot_receiver_queue')['entries']
  waiting=sorted([x['value'] for x in entries if x['value']['state']=='waiting'],key=lambda e:e['_order'])
  self.assertEqual(waiting[0]['userId'],22)
 def test_concurrent_joins_unique_order(self):
  with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
   results=list(pool.map(self.put,range(100,112)))
  self.assertEqual(len({r['_order'] for r in results}),12)
 def test_expired_receiver_cannot_preempt(self):
  first=self.put(1);second=self.put(2)
  with self.server.store.lock,self.server.store.db:
   self.server.store.db.execute('UPDATE records SET updated=? WHERE key=?',(time.time()-20,'sentinel/.cache/rot_receiver_queue/1.json'))
  resumed=self.put(1)
  self.assertGreater(resumed['_order'],second['_order'])
 def test_delete_and_persistence(self):
  item=self.put(1)
  other=relay.Store(self.db)
  self.assertEqual(other.get('sentinel/.cache/rot_receiver_queue/1.json')['_order'],item['_order']);other.close()
  self.call('DELETE','/v1/item?key=sentinel/.cache/rot_receiver_queue/1.json')
  self.assertIsNone(self.call('GET','/v1/item?key=sentinel/.cache/rot_receiver_queue/1.json').get('value'))

if __name__=='__main__':unittest.main(verbosity=2)
