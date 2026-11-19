#!/usr/bin/env python3
"""Low-traffic CF latency selection; private credentials never leave the VPS."""
import argparse, base64, copy, csv, fcntl, hashlib, ipaddress, json, os, pathlib
import random, re, shutil, socket, ssl, subprocess, tempfile, time, urllib.request

ROOT=pathlib.Path('/root/private-subscriptions')
EXPORT='/usr/local/sbin/export-private-subscriptions'
FIXED_URL='https://raw.githubusercontent.com/ywsqbw1234/vps-tools/main/cf_fixed_ip.txt'
RANGES_URL='https://www.cloudflare.com/ips-v4/'

def parse_fixed(text):
    result=[];seen=set()
    for number,line in enumerate(text.splitlines(),1):
        line=line.strip()
        if not line or line.startswith('#'):continue
        bits=line.split();target=bits[-1];label=' '.join(bits[:-1])
        if len(label)>80:raise ValueError('Fixed label too long on line '+str(number))
        host,sep,port=target.rpartition(':')
        if not sep:host,port=target,'443'
        if not port.isdigit() or not 1<=int(port)<=65535:raise ValueError('Invalid port on line '+str(number))
        try:
            ip=ipaddress.ip_address(host)
            if ip.version!=4 or not ip.is_global:raise ValueError('Fixed IP must be public IPv4')
        except ValueError:
            if re.fullmatch(r'[0-9.]+',host) or not re.fullmatch(r'(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',host):
                raise ValueError('Invalid public IPv4/domain on line '+str(number))
        key=(host.lower(),int(port))
        if key in seen:continue
        seen.add(key);result.append((label,host,int(port)))
    if not result:raise ValueError('Fixed list is empty; previous subscription retained')
    if len(result)>100:raise ValueError('At most 100 fixed entries are allowed')
    return result

def replace_group_nodes(template,names):
    result=copy.deepcopy(template)
    for group in result['proxy-groups']:
        members=group.get('proxies',[]);updated=[];inserted=False
        for name in members:
            if name.startswith(('DE-FIX','DE-CF')):
                if not inserted:updated.extend(names);inserted=True
            else:updated.append(name)
        group['proxies']=updated
    return result

def fetch(url):
    request=urllib.request.Request(url,headers={'Cache-Control':'no-cache','User-Agent':'private-cf-updater/1'})
    with urllib.request.urlopen(request,timeout=20) as response:
        data=response.read(131073)
    if len(data)>131072:raise ValueError('Source file too large')
    return data.decode('utf-8-sig')

def probe(host,port,domain,path):
    """Validate TLS and WS upgrade, without sending VMess credentials."""
    try:
        addresses=socket.getaddrinfo(host,port,socket.AF_INET,socket.SOCK_STREAM)
        address=addresses[0][4][0]
        if not ipaddress.ip_address(address).is_global:return False
        key=base64.b64encode(os.urandom(16)).decode()
        expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        with socket.create_connection((address,port),timeout=5) as sock:
            with ssl.create_default_context().wrap_socket(sock,server_hostname=domain) as tls:
                tls.settimeout(5)
                req='GET '+path+' HTTP/1.1\r\nHost: '+domain+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n'
                tls.sendall(req.encode());data=b''
                while b'\r\n\r\n' not in data and len(data)<16384:
                    part=tls.recv(4096)
                    if not part:break
                    data+=part
                header=data.decode('latin1');lines=header.split('\r\n')
                headers={k.lower():v.strip() for l in lines[1:] if ':' in l for k,v in [l.split(':',1)]}
                return ' 101 ' in lines[0] and headers.get('sec-websocket-accept')==expected
    except (OSError,ValueError):return False

def build_nodes(current,live,fixed,auto):
    native=next(n for n in current if n['name'].startswith(('DE-FIX','DE-CF')))
    inbound=next(i for i in live['inbounds'] if i['tag']=='vmess-ws-native')
    native=copy.deepcopy(native);native['uuid']=inbound['users'][0]['uuid'];native['ws-opts']['path']=inbound['transport']['path']
    nodes=[]
    for index,(label,host,port) in enumerate(fixed,1):
        node=copy.deepcopy(native);node.update(name='DE-FIX%02d'%index+('-'+label if label else ''),server=host,port=port);nodes.append(node)
    for index,host in enumerate(auto,1):
        node=copy.deepcopy(native);node.update(name='DE-CF%02d'%index,server=host,port=443);nodes.append(node)
    fixed_by_label={label:(host,port) for label,host,port in fixed}
    for n in current:
        if n['name'].startswith('CF-WARP-'):
            n=copy.deepcopy(n);label={'CF-WARP-yx':'yx','CF-WARP-japan2':'japan2'}.get(n['name'])
            if label in fixed_by_label:n['server'],n['port']=fixed_by_label[label]
            nodes.append(n)
    return nodes

def run(args):
    os.umask(0o077)
    if os.geteuid()!=0:raise ValueError('Run this command as root on the German VPS')
    with (ROOT/'update.lock').open('w') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise ValueError('An IP update is already running')
        cache=ROOT/'fixed-ip-cache.txt'
        if args.fixed_file:
            fixed_text=pathlib.Path(args.fixed_file).read_text();source='local override'
        else:
            try:fixed_text=fetch(FIXED_URL+'?t='+str(int(time.time())));source='GitHub'
            except (OSError,ValueError):
                if not cache.exists():raise ValueError('GitHub fetch failed and no validated cache exists')
                fixed_text=cache.read_text();source='last validated local cache (GitHub unavailable)'
        fixed=parse_fixed(fixed_text)
        current=json.loads((ROOT/'cf-proxies.json').read_text());live=json.loads(pathlib.Path('/etc/sing-box-cf/config.json').read_text())
        native=next(i for i in live['inbounds'] if i['tag']=='vmess-ws-native')
        path=native['transport']['path'];domain=next(n for n in current if n['name'].startswith(('DE-FIX','DE-CF')))['servername']
        print('[cfsub] Fixed entries:',len(fixed),'source:',source,flush=True)
        with tempfile.TemporaryDirectory(prefix='cf-update-',dir=ROOT) as temp:
            stage=pathlib.Path(temp)
            if args.fixed_only:
                auto=[n['server'] for n in current if n['name'].startswith('DE-CF')]
            else:
                nets=[ipaddress.ip_network(x.strip()) for x in fetch(RANGES_URL).splitlines() if x.strip()]
                if not nets or any(n.version!=4 or not n.is_global for n in nets):raise ValueError('Invalid Cloudflare ranges')
                fixed_ips={host for _,host,_ in fixed}
                candidates=[n['server'] for n in current if n['name'].startswith('DE-CF') and n['server'] not in fixed_ips and any(ipaddress.ip_address(n['server']) in net for net in nets)]
                rng=random.SystemRandom();attempts=0
                while len(candidates)<args.candidates and attempts<args.candidates*20:
                    attempts+=1;net=nets[attempts%len(nets)];ip=str(net.network_address+rng.randrange(1,net.num_addresses-1))
                    if ip not in candidates and ip not in fixed_ips:candidates.append(ip)
                candidates=candidates[:args.candidates]
                (stage/'ips.txt').write_text('\n'.join(candidates)+'\n')
                print('[cfsub] TCP latency test:',len(candidates),'IPs, 8 workers, no bulk downloads',flush=True)
                result=subprocess.run(['cfst','-f',str(stage/'ips.txt'),'-o',str(stage/'result.csv'),'-dd','-n','8','-t','3','-tlr','0.34','-p','0'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=240)
                if result.returncode or not (stage/'result.csv').exists():raise ValueError('Latency test failed; old subscription retained')
                with (stage/'result.csv').open(encoding='utf-8-sig') as stream:rows=list(csv.reader(stream))[1:]
                ranked=[row[0] for row in rows if row and row[0] in candidates]
                auto=[]
                print('[cfsub] Checking TLS and private WebSocket entry...',flush=True)
                for ip in ranked[:min(len(ranked),args.keep_top*3)]:
                    if probe(ip,443,domain,path):auto.append(ip)
                    if len(auto)>=args.keep_top:break
                if len(auto)<args.keep_top:raise ValueError('Not enough working automatic IPs; old subscription retained')
            nodes=build_nodes(current,live,fixed,auto)
            names=[n['name'] for n in nodes if n['name'].startswith(('DE-FIX','DE-CF'))]
            template=replace_group_nodes(json.loads((ROOT/'routing-template.json').read_text()),names)
            (stage/'cf-proxies.json').write_text(json.dumps(nodes,ensure_ascii=False));(stage/'routing-template.json').write_text(json.dumps(template,ensure_ascii=False))
            if (ROOT/'extra-proxies.json').exists():shutil.copy2(ROOT/'extra-proxies.json',stage/'extra-proxies.json')
            env=dict(os.environ,CFSUB_DATA_DIR=str(stage),CFSUB_NO_PUBLISH='1')
            subprocess.run([EXPORT],env=env,check=True,stdout=subprocess.DEVNULL)
            output=json.loads((stage/'Germany-Direct.yaml').read_text())
            valid={p['name'] for p in output['proxies']}|{g['name'] for g in output['proxy-groups']}|{'DIRECT','REJECT'}
            if len({p['name'] for p in output['proxies']})!=len(output['proxies']):raise ValueError('Duplicate node names')
            for group in output['proxy-groups']:
                if any(name not in valid for name in group['proxies']):raise ValueError('Invalid group reference')
            assert output['rules']==template['rules']
            if args.dry_run:
                print('[cfsub] Dry run passed:',len(fixed),'fixed +',len(auto),'automatic; online subscription unchanged');return
            # All network/testing work finished before publication. Keep rollback copies.
            with (ROOT/'export.lock').open('w') as publication_lock:
                fcntl.flock(publication_lock,fcntl.LOCK_EX)
                backup=ROOT/'update-backups'/time.strftime('%Y%m%d-%H%M%S');backup.mkdir(parents=True,mode=0o700)
                files=['cf-proxies.json','routing-template.json','Germany-Direct.yaml','Germany-Direct-links.txt','Germany-Direct-sub.txt']
                for name in files:shutil.copy2(ROOT/name,backup/name)
                served=pathlib.Path('/srv/private-subscriptions')
                for name in ['clash.yaml','sub.txt']:shutil.copy2(served/name,backup/('served-'+name))
                try:
                    for name in ['cf-proxies.json','routing-template.json']:
                        temporary=ROOT/(name+'.new');shutil.copy2(stage/name,temporary);temporary.replace(ROOT/name)
                    subprocess.run([EXPORT],env=dict(os.environ,CFSUB_LOCK_HELD='1'),check=True)
                except Exception:
                    for name in files:shutil.copy2(backup/name,ROOT/name)
                    for name in ['clash.yaml','sub.txt']:shutil.copy2(backup/('served-'+name),served/name)
                    raise ValueError('Publication failed; previous files restored')
                cache.write_text(fixed_text)
            print('[cfsub] HTTPS subscription updated:',len(fixed),'fixed +',len(auto),'automatic. Credentials and running services unchanged.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixed-only',action='store_true',help='Refresh fixed nodes while retaining current automatic nodes')
    parser.add_argument('--fixed-file',help='Use a local fixed IP list instead of GitHub')
    parser.add_argument('--dry-run',action='store_true',help='Test and validate without changing the subscription')
    parser.add_argument('--candidates',type=int,default=80)
    parser.add_argument('--keep-top',type=int,default=12)
    args=parser.parse_args()
    try:
        if not 1<=args.keep_top<=24 or not args.keep_top<=args.candidates<=160:raise ValueError('Use 1..24 selected IPs and up to 160 candidates')
        run(args)
    except Exception as exc:
        print('[cfsub] ERROR:',str(exc) if isinstance(exc,ValueError) else type(exc).__name__,flush=True)
        raise SystemExit(1)
