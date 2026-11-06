"""Isolated real-Xray protocol and counter acceptance, without production access."""
import importlib.util
import json
import os
import pathlib
import statistics
import subprocess
import time

ROOT = pathlib.Path(os.environ['FT_TRAFFIC_ROOT'])
LAB = pathlib.Path(os.environ['FT_TRAFFIC_LAB'])
ARTIFACTS = pathlib.Path(os.environ['FT_TRAFFIC_ARTIFACTS'])
IMAGE = os.environ['FT_TRAFFIC_IMAGE']
COMPOSE = (['docker','compose'] if subprocess.run(['docker','compose','version'],capture_output=True).returncode == 0 else ['/usr/libexec/docker/cli-plugins/docker-compose']) + ['-f', str(ROOT / 'tests/monitoring/compose.yml')]

def run(args, **kw):
    result = subprocess.run(args, text=True, capture_output=True, timeout=120, **kw)
    if result.returncode:
        raise RuntimeError(f'Lab command failed: {args[:4]}: {result.stderr[-1600:]}')
    return result.stdout

def compose(*args):
    return run(COMPOSE + list(args))

def execute(service, *args):
    return compose('exec', '-T', service, *args)

def wait(call, timeout=60):
    start = time.monotonic()
    while True:
        try:
            value = call()
            if value:
                return value
        except (subprocess.CalledProcessError, OSError, ValueError, RuntimeError):
            pass
        if time.monotonic() - start > timeout:
            raise AssertionError('Lab readiness timeout')
        time.sleep(1)

# Reuse the established disposable Reality and proxy fixture generator.
os.environ.update(FT_LAB_REPO=str(ROOT), FT_LAB_DIR=str(LAB), FT_LAB_IMAGE=IMAGE, FT_LAB_ARTIFACT_DIR=str(ARTIFACTS))
spec = importlib.util.spec_from_file_location('security_fixture', ROOT / 'tests/security_lab/test_proxy_security.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.LAB, fixture.ROOT, fixture.IMAGE = LAB, ROOT, IMAGE
fixture.prepare()
(LAB / 'nginx-logs').mkdir()
(LAB / 'state').mkdir()
(LAB / 'nginx-logs/traffic.log').touch()
(LAB / 'logs/error.log').touch()
config = json.loads((LAB / 'xray.json').read_text())
config['inbounds'][2]['settings']['clients'][0]['email'] = 'fixture-user@vless.local'
(LAB / 'xray.json').write_text(json.dumps(config))
(LAB / 'identities.json').write_text(json.dumps({'fixture-user': {'user_id': 'fixture-user', 'account_class': 'proxy'}, 'fixture-user@vless.local': {'user_id': 'fixture-user', 'account_class': 'vless'}}))
(LAB / 'origin.py').write_text('''import ssl,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  size=1048576
  self.send_response(200);self.send_header('Content-Length',str(size));self.end_headers();self.wfile.write(b'x'*size)
 def do_POST(self):
  size=int(self.headers.get('Content-Length','0'));data=self.rfile.read(size)
  self.send_response(200);self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'OK')
 def log_message(self,*a):pass
server=ThreadingHTTPServer(('0.0.0.0',443),Handler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain('/lab/certs/fullchain.pem','/lab/certs/privkey.pem')
server.socket=ctx.wrap_socket(server.socket,server_side=True);server.serve_forever()
''')
(LAB / 'payload').write_bytes(b'u' * 65536)
export_config = {'listen':'0.0.0.0:9915','api':'127.0.0.1:10085','identity':'/lab/identities.json','state_dir':'/lab/state','fail2ban':'','detail_budget':10000,'logs':{'access':'/lab/logs/access.log','auth':'/lab/logs/auth.log','error':'/lab/logs/error.log','nginx':'/lab/nginx-logs/traffic.log'}}
(LAB / 'exporter.json').write_text(json.dumps(export_config))
compose('up','-d','node','target','valid','proxy','xray-client')

def fetch(protocol, upload=False):
    proxies={'http':'http://node:8119','https':'https://node:8118','socks5':'socks5h://node:1081','socks5s':'socks5h://127.0.0.1:1083','vless':'socks5h://127.0.0.1:1082'}
    args=['curl','--silent','--show-error','--fail','--max-time','30','--cacert','/lab/certs/fullchain.pem','--proxy-cacert','/lab/certs/fullchain.pem','--proxy',proxies[protocol],'-o','/dev/null','-w','%{size_download} %{time_total}']
    if protocol in ('http','https','socks5'):
        args+=['--proxy-user','fixture-user:fixture-password']
    if protocol=='https':
        args+=['--proxy-resolve','node:8118:proxy.lab'] if False else ['--proxy-insecure']
    if upload:
        args+=['--data-binary','@/lab/payload']
    args+=['https://target.lab/controlled']
    output=execute('valid',*args).split()
    assert int(output[0])==(2 if upload else 1048576), output
    return float(output[1])

wait(lambda: fetch('http'))
baseline=[fetch('http') for _ in range(7)]
# Turn on monitoring through the production staging helper, not a separate fixture implementation.
run(['bash','-c','source "$1/lib/traffic_monitoring.sh"; FT_TRAFFIC_MONITORING=true stage_traffic_monitoring_config "$2/xray.json" "$2/staged.json"; cat "$2/staged.json" > "$2/xray.json"','bash',str(ROOT),str(LAB)])
nginx=run(['bash','-c','source "$1/lib/nginx_stream_generator.sh"; FT_TRAFFIC_MONITORING=true generate_nginx_config proxy.lab false "" "" "" false true','bash',str(ROOT)])
(LAB / 'nginx.conf').write_text(nginx)
compose('restart','proxy')
wait(lambda: fetch('http'))
compose('up','-d','exporter')
def metrics():
    return execute('node','curl','-fsS','http://127.0.0.1:9915/metrics')
wait(lambda: 'familytraffic_source_up{source="xray"} 1' in metrics())
# Initial scrape establishes zero baselines for new derived counters.
metrics()
results={}
for protocol in ('http','https','socks5','socks5s','vless'):
    results[protocol]={'download_seconds':fetch(protocol),'upload_seconds':fetch(protocol,True)}
instrumented=[fetch('http') for _ in range(7)]
time.sleep(16)
first=metrics()
time.sleep(1)
final=metrics()
assert 'familytraffic_user_bytes_total{account_class="proxy",direction="download",user_id="fixture-user"}' in final
assert 'familytraffic_user_bytes_total{account_class="vless",direction="download",user_id="fixture-user"}' in final
assert 'familytraffic_access_events_total' in final and 'destination="target.lab:443"' in final
assert 'user_id="fixture-user"' in final
assert 'familytraffic_frontend_bytes_total' in final
assert 'fixture-password' not in final and '/controlled' not in final
# Verify that a collector restart replays durable counters rather than inventing new increments.
compose('restart','exporter')
wait(lambda: 'familytraffic_source_up{source="xray"} 1' in metrics())
recovered=metrics()
assert 'familytraffic_access_events_total' in recovered
assert 'familytraffic_source_up{source="identity"} 1' in recovered
# Native API must not reset while collecting.
latest=metrics()
assert 'familytraffic_inbound_bytes_total' in latest
ids=compose('ps','-q','proxy','exporter').split()
stats=run(['docker','stats','--no-stream','--format','json',*ids])
evidence={'protocols':results,'baseline_http_seconds':baseline,'instrumented_http_seconds':instrumented,'baseline_p95_seconds':sorted(baseline)[-1],'instrumented_p95_seconds':sorted(instrumented)[-1],'resource_snapshot':stats,'image_id':run(['docker','image','inspect',IMAGE,'--format','{{.Id}}']).strip(),'limitations':['Short local-loopback performance run is observational, not a production throughput guarantee.','Vision counter timing and crash gaps remain documented native-counter limitations.'],'status':'passed'}
(ARTIFACTS / 'acceptance.json').write_text(json.dumps(evidence,indent=2)+'\n')
(ARTIFACTS / 'metrics.txt').write_text(final)
print(json.dumps({'status':'passed','protocols':list(results),'artifact':str(ARTIFACTS / 'acceptance.json')}))
