#!/usr/bin/env python3
"""Export root-only direct subscriptions. No network requests or Git publishing."""
import base64, hashlib, json, os, pathlib, ssl, urllib.parse
if os.geteuid() != 0:
    raise SystemExit('Run as root on the German VPS.')
os.umask(0o077)
dest = pathlib.Path('/root/private-subscriptions')
dest.mkdir(mode=0o700, exist_ok=True)
config = json.loads(pathlib.Path('/etc/sing-box/config.json').read_text())
template = json.loads((dest / 'routing-template.json').read_text())
names = {38049:'DE-HY2-直连',38050:'DE-HY2-15M',38051:'DE-HY2-30M'}
proxies=[]; links=[]
for inbound in config['inbounds']:
    if inbound['type'] != 'hysteria2': continue
    port=inbound['listen_port']; name=names[port]
    password=inbound['users'][0]['password']
    cert=pathlib.Path(inbound['tls']['certificate_path']).read_text()
    fingerprint=hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest()
    node={'name':name,'type':'hysteria2','server':'82.139.205.22','port':port,
          'password':password,'sni':'bing.com','skip-cert-verify':False,
          'fingerprint':fingerprint,'udp':True}
    if inbound.get('up_mbps'):node['up']=str(inbound['up_mbps'])+' Mbps'
    if inbound.get('down_mbps'):node['down']=str(inbound['down_mbps'])+' Mbps'
    proxies.append(node)
    query=urllib.parse.urlencode({'sni':'bing.com','insecure':'1','pinSHA256':fingerprint})
    links.append('hysteria2://'+urllib.parse.quote(password,safe='')+'@82.139.205.22:'+str(port)+'/?'+query+'#'+urllib.parse.quote(name))
if len(proxies)!=3:raise SystemExit('Expected exactly three direct inbounds')
template['proxies']=proxies
template['allow-lan']=False
template['bind-address']='127.0.0.1'
template.pop('proxy-providers',None)
node_names=[p['name'] for p in proxies]
groups=template.get('proxy-groups',[])
group_names={g['name'] for g in groups}
for group in groups:
    kept=[p for p in group.get('proxies',[]) if p in group_names or p in ['DIRECT','REJECT']]
    group.pop('use',None)
    # Preserve application groups/rules, replacing obsolete nodes with direct nodes.
    group['proxies']=list(dict.fromkeys(node_names+kept))
def write(name,value):
    target=dest/name; temporary=dest/(name+'.tmp')
    temporary.write_text(value,encoding='utf-8'); temporary.chmod(0o600); temporary.replace(target)
write('Germany-Direct.yaml',json.dumps(template,ensure_ascii=False,indent=2)+'\n')
write('Germany-Direct-links.txt','\n'.join(links)+'\n')
write('Germany-Direct-sub.txt',base64.b64encode(('\n'.join(links)+'\n').encode()).decode())
print('Private subscriptions refreshed: 3 direct nodes, root-only files, no upload.')
