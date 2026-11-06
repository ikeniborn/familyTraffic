"""Isolated real-Xray protocol and counter acceptance, without production access."""
import importlib.util
import json
import os
import pathlib
import statistics
import math
import re
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
  size=4194304 if self.path in ('/large','/slow') else 1048576
  self.send_response(200);self.send_header('Content-Length',str(size));self.end_headers()
  if self.path == '/slow':
   for _ in range(64):self.wfile.write(b'x'*65536);self.wfile.flush();time.sleep(0.5)
  else:self.wfile.write(b'x'*size)
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
(LAB / 'benchmark.py').write_text("""import concurrent.futures,json,subprocess,time
args=['curl','-fsS','--max-time','60','--cacert','/lab/certs/fullchain.pem','--proxy','http://node:8119','--proxy-user','fixture-user:fixture-password','-o','/dev/null','-w','%{size_download} %{time_total}','https://target.lab/large']
def request(_):
 result=subprocess.run(args,capture_output=True,text=True,check=True).stdout.split()
 assert int(result[0])==4194304
 return float(result[1])
start=time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:times=list(executor.map(request,range(32)))
elapsed=time.perf_counter()-start
print(json.dumps({'requests':32,'bytes':32*4194304,'elapsed_seconds':elapsed,'throughput_bytes_per_second':32*4194304/elapsed,'request_seconds':times}))
""")
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
def cgroup(service):
    text=execute(service,'sh','-c',"cat /sys/fs/cgroup/cpu.stat; cat /sys/fs/cgroup/memory.current; awk '/^Name:/{include=($2==\"xray\"||$2==\"nginx\"||$2==\"familytraffic-e\"||$2==\"exporter\")}/^VmRSS:/{if(include)rss+=$2}END{printf \"%.0f\\n\",rss*1024}' /proc/[0-9]*/status")
    values=text.splitlines()
    return {'cpu_usage_usec':int(next(v.split()[1] for v in values if v.startswith('usage_usec '))), 'memory_current_bytes':int(values[-2]),'process_rss_bytes':int(values[-1])}
def disk_bytes():
    return sum(p.stat().st_size for name in ('logs','nginx-logs','state') for p in (LAB/name).rglob('*') if p.is_file())
def benchmark():
    before=cgroup('proxy');disk_before=disk_bytes()
    exporter_present=bool(compose('ps','-q','exporter').strip())
    exporter_before=cgroup('exporter') if exporter_present else {'cpu_usage_usec':0,'memory_current_bytes':0,'process_rss_bytes':0}
    data=json.loads(execute('valid','python3','/lab/benchmark.py'))
    after=cgroup('proxy')
    exporter_after=cgroup('exporter') if exporter_present else {'cpu_usage_usec':0,'memory_current_bytes':0,'process_rss_bytes':0}
    data.update(cpu_usage_usec=after['cpu_usage_usec']-before['cpu_usage_usec'],memory_before_bytes=before['memory_current_bytes'],memory_after_bytes=after['memory_current_bytes'],disk_growth_bytes=disk_bytes()-disk_before,exporter_cpu_usage_usec=exporter_after['cpu_usage_usec']-exporter_before['cpu_usage_usec'],exporter_memory_before_bytes=exporter_before['memory_current_bytes'],exporter_memory_after_bytes=exporter_after['memory_current_bytes'],process_rss_before_bytes=before['process_rss_bytes'],process_rss_after_bytes=after['process_rss_bytes'],exporter_rss_before_bytes=exporter_before['process_rss_bytes'],exporter_rss_after_bytes=exporter_after['process_rss_bytes'])
    return data
baseline=[benchmark() for _ in range(3)]
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
# Parse actual numerical samples, not only metric-name presence.
def samples(text):
    values={}
    for line in text.splitlines():
        match=re.match(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? ([^ ]+)',line)
        if not match:continue
        labels={k:json.loads('"'+v+'"') for k,v in re.findall(r'(\w+)="((?:\\.|[^"\\])*)"',match[2] or '')}
        values[(match[1],tuple(sorted(labels.items())))]=float(match[3])
    return values

def total(values,metric,**filters):
    return sum(value for (name,labels),value in values.items() if name==metric and all(dict(labels).get(k)==v for k,v in filters.items()))

before=samples(metrics())
results={}
for protocol in ('http','https','socks5','socks5s','vless'):
    results[protocol]={'download_seconds':fetch(protocol),'upload_seconds':fetch(protocol,True)}
instrumented=[benchmark() for _ in range(3)]
# Both polls and all completed sessions must settle before comparing totals.
time.sleep(16)
metrics()
time.sleep(1)
final=metrics()
after=samples(final)
expected={'http-proxy':4+3*32,'socks5-proxy':4,'reality':2}
observed={inbound:total(after,'familytraffic_access_total',inbound=inbound,status='accepted')-total(before,'familytraffic_access_total',inbound=inbound,status='accepted') for inbound in expected}
# Preserve synthetic metadata before assertions to diagnose parser coverage honestly.
synthetic_access=execute('proxy','cat','/var/log/xray/access.log')
(ARTIFACTS/'synthetic-access.txt').write_text(synthetic_access)
assert observed==expected, {'expected_access':expected,'observed_access':observed}
detail={inbound:total(after,'familytraffic_access_events_total',inbound=inbound)-total(before,'familytraffic_access_events_total',inbound=inbound) for inbound in expected}
assert detail==expected, {'expected_detail':expected,'observed_detail':detail}
for inbound in ('http-proxy','socks5-proxy'):
    assert total(after,'familytraffic_access_events_total',inbound=inbound,user_id='unknown')==detail[inbound], 'Pinned proxy access logs must preserve unknown identity'
assert total(after,'familytraffic_access_events_total',inbound='reality',user_id='fixture-user')==detail['reality'], 'VLESS email mapping lost'
# Byte floors come from known payloads. TLS/HTTP framing is deliberately not equated to payload bytes.
byte_floors={'proxy':{'download':4*1048576+3*32*4194304,'upload':4*65536},'vless':{'download':1048576,'upload':65536}}
byte_deltas={}
for account_class,directions in byte_floors.items():
    byte_deltas[account_class]={}
    for direction,floor in directions.items():
        delta=total(after,'familytraffic_user_bytes_total',account_class=account_class,direction=direction)-total(before,'familytraffic_user_bytes_total',account_class=account_class,direction=direction)
        assert delta>=floor, (account_class,direction,delta,floor)
        byte_deltas[account_class][direction]=delta
assert 'fixture-password' not in final and '/controlled' not in final
# No new proxy traffic while restarting: all durable derived samples must be identical.
tracked=('familytraffic_access_total','familytraffic_access_events_total','familytraffic_frontend_bytes_total','familytraffic_frontend_sessions_total')
derived_before={k:v for k,v in after.items() if k[0] in tracked}
compose('restart','exporter')
wait(lambda: 'familytraffic_source_up{source="xray"} 1' in metrics())
recovered=samples(metrics())
derived_after={k:v for k,v in recovered.items() if k[0] in tracked}
assert derived_after==derived_before, {'restart_before':derived_before,'restart_after':derived_after}
# Keep a real Vision flow active across an exporter poll, then observe its closure.
long_before=samples(metrics())
args=COMPOSE+['exec','-T','valid','curl','-fsS','--max-time','60','--cacert','/lab/certs/fullchain.pem','--proxy','socks5h://127.0.0.1:1082','-o','/dev/null','-w','%{size_download} %{time_total}','https://target.lab/slow']
process=subprocess.Popen(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
time.sleep(17)
assert process.poll() is None, 'Vision flow did not remain active across poll'
long_during=samples(metrics())
output,error=process.communicate(timeout=60)
assert process.returncode==0,error
assert int(output.split()[0])==4194304,output
time.sleep(16)
metrics();long_after=samples(metrics())
long_values={name:total(values,'familytraffic_user_bytes_total',account_class='vless',direction='download') for name,values in [('before',long_before),('during',long_during),('after',long_after)]}
assert long_values['after']-long_values['before']>=4194304,long_values
assert long_values['during']>=long_values['before'],long_values
exporter_resources=cgroup('exporter')
perf={}
for name,runs in [('baseline',baseline),('instrumented',instrumented)]:
    latencies=sorted(v for batch in runs for v in batch['request_seconds'])
    perf[name]={'runs':runs,'median_throughput_bytes_per_second':statistics.median(batch['throughput_bytes_per_second'] for batch in runs),'request_p95_seconds':latencies[math.ceil(.95*len(latencies))-1],'total_cpu_usage_usec':sum(batch['cpu_usage_usec'] for batch in runs),'maximum_observed_memory_bytes':max(batch['memory_after_bytes'] for batch in runs),'maximum_observed_process_rss_bytes':max(batch['process_rss_after_bytes'] for batch in runs),'maximum_observed_exporter_rss_bytes':max(batch['exporter_rss_after_bytes'] for batch in runs),'disk_growth_bytes':sum(batch['disk_growth_bytes'] for batch in runs)}
perf['throughput_change_fraction']=perf['instrumented']['median_throughput_bytes_per_second']/perf['baseline']['median_throughput_bytes_per_second']-1
perf['p95_latency_change_fraction']=perf['instrumented']['request_p95_seconds']/perf['baseline']['request_p95_seconds']-1
perf['proposed_thresholds_met'] = perf['throughput_change_fraction'] >= -0.05 and perf['p95_latency_change_fraction'] <= 0.10
perf['exporter']=exporter_resources
assertions={'access_counts':observed,'detail_counts':detail,'known_payload_byte_floors':byte_floors,'native_user_byte_deltas':byte_deltas,'durable_restart_samples_compared':len(derived_before),'durable_restart_equal':True,'long_vision':{'payload_bytes':4194304,'duration_seconds':float(output.split()[1]),'download_counter_values':long_values}}
evidence={'protocols':results,'numeric_assertions':assertions,'comparative_performance':perf,'image_id':run(['docker','image','inspect',IMAGE,'--format','{{.Id}}']).strip(),'limitations':['Comparative local workload is three runs per mode, 32 requests with eight concurrent workers per run; it is not a production throughput guarantee.','Native byte floors include payload only; observed counters include boundary-specific protocol overhead.','Vision native counter timing is observed, not replaced by new transfer instrumentation.'],'status':'passed'}
(ARTIFACTS/'acceptance.json').write_text(json.dumps(evidence,indent=2)+'\n')
(ARTIFACTS/'metrics.txt').write_text(final)
print(json.dumps({'status':'passed','protocols':list(results),'numeric_assertions':assertions,'performance_changes':{k:v for k,v in perf.items() if k.endswith('_fraction')},'artifact':str(ARTIFACTS/'acceptance.json')}))
