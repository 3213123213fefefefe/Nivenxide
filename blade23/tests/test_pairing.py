import importlib.util
import json
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler

spec=importlib.util.spec_from_file_location('blade_easy',str(Path(__file__).resolve().parents[1]/'blade23_server.py'))
relay=importlib.util.module_from_spec(spec);spec.loader.exec_module(relay)

class EasyConnectTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory()
  self.token='only-test-credential-1234567890'
  self.server=relay.make_server('0.0.0.0',0,self.token,str(Path(self.temp.name)/'state.db'))
  self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
  self.base='http://127.0.0.1:'+str(self.server.server_port)
  self.http=build_opener(ProxyHandler({}))
 def tearDown(self):
  self.server.shutdown();self.server.server_close();self.server.store.close();self.thread.join();self.temp.cleanup()
 def call(self,method,path,payload=None,headers=None,base=None):
  req=Request((base or self.base)+path,data=json.dumps(payload).encode() if payload is not None else None,
   method=method,headers={'Content-Type':'application/json',**(headers or {})})
  with self.http.open(req,timeout=3) as response:
   content=response.read()
   return json.loads(content) if 'application/json' in response.headers.get('Content-Type','') else content.decode()
 def test_one_click_local_auth_and_invitation(self):
  setup=self.call('GET','/')
  self.assertIn('Copiar convite',setup)
  self.assertNotIn(self.token,setup)
  local=self.call('POST','/v1/local-connect',{})
  self.assertEqual(local['token'],self.token)
  self.assertEqual(local['version'],2)
  invitation=self.call('GET','/v1/local-invitation')
  self.assertGreater(invitation['expiresIn'],590)
  self.assertTrue(invitation['invitations'][0]['invite'].startswith('B23|http://'))
  self.assertNotIn(self.token,json.dumps(invitation))
 def test_code_pairs_and_credential_authorizes_real_queue(self):
  invitation=self.call('GET','/v1/local-invitation')['invitations'][0]['invite']
  code=invitation.split('|')[-1]
  response=self.call('POST','/v1/pair',{'code':code.lower()})
  key=response['token']
  headers={'Authorization':'Bearer '+key}
  self.assertEqual(self.call('GET','/v1/health',headers=headers)['service'],'blade23')
  record={'key':'sentinel/.cache/rot_receiver_queue/1.json','value':{'joined':1,'userId':1,'state':'waiting','jobId':'server'}}
  self.assertTrue(self.call('POST','/v1/item',record,headers=headers)['ok'])
  self.assertEqual(len(self.call('GET','/v1/list?prefix=sentinel/.cache/rot_receiver_queue',headers=headers)['entries']),1)
 def test_wrong_expired_rotated_and_rate_limited(self):
  for _ in range(8):
   with self.assertRaises(HTTPError) as err:self.call('POST','/v1/pair',{'code':'WRONG000'})
   self.assertEqual(err.exception.code,401)
  with self.assertRaises(HTTPError) as err:self.call('POST','/v1/pair',{'code':self.server.pairing.code})
  self.assertEqual(err.exception.code,429)
  old=self.server.pairing.code
  self.call('POST','/v1/local-invitation',{})
  self.assertNotEqual(old,self.server.pairing.code)
  with self.assertRaises(HTTPError) as err:self.call('POST','/v1/pair',{'code':old})
  self.assertEqual(err.exception.code,401)
  self.server.pairing.deadline=time.monotonic()-1
  with self.assertRaises(HTTPError) as err:self.call('POST','/v1/pair',{'code':self.server.pairing.code})
  self.assertEqual(err.exception.code,410)
  self.assertEqual(self.call('POST','/v1/local-invitation',{})['version'],2)
  # Renewing an invitation must not invalidate accounts that have connected.
  self.assertEqual(self.call('GET','/v1/health',headers={'Authorization':'Bearer '+self.token})['version'],2)
 def test_local_routes_deny_rebinding_cross_origin_and_lan_clients(self):
  for headers in [{'Host':'attacker.invalid'},{'Origin':'https://other.invalid'},{'Sec-Fetch-Site':'cross-site'}]:
   with self.assertRaises(HTTPError) as err:self.call('POST','/v1/local-connect',{},headers=headers)
   self.assertEqual(err.exception.code,403)
  # This runner has no routable LAN interface. Simulate the remote address
  # decision while still exercising the real HTTP routes and response bodies.
  with patch.object(relay.ipaddress,'ip_address',return_value=SimpleNamespace(is_loopback=False)):
   with self.assertRaises(HTTPError) as err:self.call('POST','/v1/local-connect',{})
   self.assertEqual(err.exception.code,403)
   with self.assertRaises(HTTPError) as err:self.call('GET','/v1/local-invitation')
   self.assertEqual(err.exception.code,403)
   self.assertEqual(self.call('POST','/v1/pair',{'code':self.server.pairing.code})['token'],self.token)
 def test_info_public_but_records_still_require_full_key(self):
  self.assertEqual(self.call('GET','/v1/info')['version'],2)
  for path in ['/v1/health','/v1/list?prefix=sentinel/.cache/rot_receiver_queue']:
   with self.assertRaises(HTTPError) as err:self.call('GET',path)
   self.assertEqual(err.exception.code,401)
  with self.assertRaises(HTTPError) as err:self.call('POST','/v1/pair',{'code':{'bad':'value'}})
  self.assertEqual(err.exception.code,401)

if __name__=='__main__':unittest.main(verbosity=2)
