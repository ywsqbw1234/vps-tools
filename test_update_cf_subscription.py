import importlib.util,pathlib,unittest,copy
spec=importlib.util.spec_from_file_location('updater',str(pathlib.Path(__file__).with_name('update_cf_subscription.py')))
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
class UpdateTests(unittest.TestCase):
 def test_fixed_order_ports_comments_dedup(self):
  self.assertEqual(u.parse_fixed('# comment\nyx 104.16.1.1\nmain de.example.com:8443\nduplicate 104.16.1.1\n'),[('yx','104.16.1.1',443),('main','de.example.com',8443)])
 def test_reject_invalid_before_mutation(self):
  for text in ['', '# only comment', 'bad 999.1.1.1','local 127.0.0.1','private 10.0.0.1','x example.com:99999','x https://example.com','x host;command']:
   with self.subTest(text=text):
    with self.assertRaises(ValueError):u.parse_fixed(text)
 def test_group_rules_and_defaults_preserved(self):
  source={'rules':['GEOIP,CN,local','MATCH,select'],'proxy-groups':[{'name':'select','type':'select','proxies':['DE-FIX01-old','DE-CF01','CF-WARP-yx','DIRECT']},{'name':'local','type':'select','proxies':['DIRECT','select']}]}
  before=copy.deepcopy(source);out=u.replace_group_nodes(source,['DE-FIX01-new','DE-CF01','DE-CF02'])
  self.assertEqual(source,before);self.assertEqual(out['rules'],source['rules'])
  self.assertEqual(out['proxy-groups'][0]['proxies'],['DE-FIX01-new','DE-CF01','DE-CF02','CF-WARP-yx','DIRECT'])
  self.assertEqual(out['proxy-groups'][1],source['proxy-groups'][1])
 def test_private_credentials_from_live_config(self):
  current=[{'name':'DE-FIX01-yx','uuid':'old-placeholder','server':'104.16.1.1','port':443,'ws-opts':{'path':'/old'},'type':'vmess'}, {'name':'CF-WARP-yx','uuid':'warp-placeholder','server':'104.16.1.2','port':443}]
  live={'inbounds':[{'tag':'vmess-ws-native','users':[{'uuid':'current-placeholder'}],'transport':{'path':'/current'}}]}
  out=u.build_nodes(current,live,[('yx','104.16.2.1',8443)],['104.16.3.1'])
  self.assertEqual(out[0]['uuid'],'current-placeholder');self.assertEqual(out[0]['ws-opts']['path'],'/current')
  self.assertEqual(out[1]['name'],'DE-CF01');self.assertEqual(out[2]['uuid'],'warp-placeholder');self.assertEqual(out[2]['port'],8443)
  self.assertEqual(current[0]['uuid'],'old-placeholder')
if __name__=='__main__':unittest.main()
