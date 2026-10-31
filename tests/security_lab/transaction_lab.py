"""Run the actual migration and rollback against a private Docker-in-Docker daemon.

No host Docker socket, host network, or host firewall files enter the node.
Only disposable named volumes hold the nested deployment and certificates.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, timeout=120, check=True, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, **kwargs)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args[:4]}\n{result.stderr[-3000:]}\n{result.stdout[-1500:]}")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--dind-image", default="docker:29-dind")
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    image = run(["docker", "image", "inspect", "--format", "{{.Id}}", args.image]).stdout.strip()
    # Fail before mutation when the requested prebuilt daemon base is unavailable.
    run(["docker", "image", "inspect", args.dind_image])
    name = "ft-transaction-" + uuid.uuid4().hex[:12]
    artifacts = args.artifacts or ROOT / "tests/security_lab/artifacts" / name
    artifacts.mkdir(parents=True, exist_ok=True)
    result = {"application_image": image, "daemon_base": args.dind_image, "checks": []}
    for relative in ["scripts/familytraffic-security", "lib/proxy_security.sh", "lib/fail2ban_setup.sh", "lib/nginx_stream_generator.sh", "tests/security_lab/node.Dockerfile", "tests/security_lab/transaction_lab.py"]:
        result.setdefault("source_sha256", {})[relative] = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
    resources = {"daemon": name + "-daemon", "node": name + "-node", "network": name + "-network", "data": name + "-data", "certs": name + "-certs", "state": name + "-state", "image": name + "-tools"}
    try:
        with tempfile.TemporaryDirectory(prefix=name) as temporary:
            directory = Path(temporary)
            dockerfile = directory / "Dockerfile"
            dockerfile.write_text("ARG DIND_IMAGE=docker:29-dind\nFROM ${DIND_IMAGE} AS docker\n" + (ROOT / "tests/security_lab/node.Dockerfile").read_text() + "\nCOPY --from=docker /usr/local/bin/docker /usr/local/bin/docker\nCOPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose\n")
            if run(["docker", "buildx", "version"], check=False).returncode == 0:
                builder = ["docker", "buildx", "build", "--load"]
            else:
                builder = ["/usr/libexec/docker/cli-plugins/docker-buildx", "build", "--load"]
            print("Building disposable transaction tools node", flush=True)
            run(builder + ["--build-arg", "DIND_IMAGE=" + args.dind_image, "--build-arg", "HTTP_PROXY=", "--build-arg", "HTTPS_PROXY=", "-f", str(dockerfile), "-t", resources["image"], str(directory)], timeout=240)
            archive = directory / "application.tar"
            with archive.open("wb") as output:
                subprocess.run(["docker", "save", image], stdout=output, check=True)
            run(["docker", "network", "create", "--internal", "--label", "ft.security.transaction=" + name, resources["network"]])
            for kind in ("data", "certs", "state"):
                run(["docker", "volume", "create", "--label", "ft.security.transaction=" + name, resources[kind]])
            print("Starting private nested daemon without a host socket", flush=True)
            run(["docker", "run", "-d", "--privileged", "--name", resources["daemon"], "--network", resources["network"], "-e", "DOCKER_TLS_CERTDIR=", "-v", resources["data"] + ":/opt/familytraffic", "-v", resources["certs"] + ":/etc/letsencrypt", "-v", resources["state"] + ":/var/lib/docker", args.dind_image, "--storage-driver=vfs", "--tls=false"])
            deadline = time.monotonic() + 60
            while run(["docker", "exec", resources["daemon"], "docker", "info"], check=False).returncode:
                if time.monotonic() > deadline:
                    raise RuntimeError("Nested daemon did not become ready")
                time.sleep(0.5)
            run(["docker", "run", "-d", "--cap-add", "NET_ADMIN", "--name", resources["node"], "--network", "container:" + resources["daemon"], "-e", "DOCKER_HOST=tcp://127.0.0.1:2375", "-e", "TZ=Europe/Moscow", "-e", "TMPDIR=/opt/familytraffic/transaction-tmp", "-e", "FT_SECURITY_TEST_URL=https://127.0.0.1:9443/", "-v", resources["data"] + ":/opt/familytraffic", "-v", resources["certs"] + ":/etc/letsencrypt", "-v", str(ROOT) + ":/repo:ro", "-v", str(directory) + ":/lab:ro", resources["image"]])

            def node(script, check=True):
                return run(["docker", "exec", resources["node"], "bash", "-euc", script], timeout=180, check=check)

            node("docker load -i /lab/application.tar >/dev/null")
            (artifacts / "isolation.json").write_text(run(["docker", "inspect", resources["daemon"], resources["node"]]).stdout)
            print("Preparing compatible legacy pair and fixture-only TLS target", flush=True)
            node(SETUP.replace("__IMAGE__", image))
            run(["docker", "exec", "-d", resources["node"], "python3", "-c", TARGET])
            node("cd /opt/familytraffic; docker compose up -d --no-build --pull never")
            time.sleep(2)
            before = json.loads(node(SNAPSHOT).stdout)
            migrated = node("/repo/scripts/familytraffic-security reconcile --image " + image)
            (artifacts / "reconcile.log").write_text(migrated.stdout + migrated.stderr)
            node("/repo/scripts/familytraffic-security check")
            after = json.loads(node(SNAPSHOT).stdout)
            assert before["image"] != after["image"] == image
            assert before["users"] == after["users"]
            assert before["inodes"] == after["inodes"]
            assert after["override"] and "acceptProxyProtocol" in after["xray"]
            result["checks"].append("actual compatible image/configuration switch; users and bind inodes preserved")
            print("Injecting failure after actual policy reconciliation", flush=True)
            failed = node(FAULT, check=False)
            (artifacts / "rollback.log").write_text(failed.stdout + failed.stderr)
            assert failed.returncode != 0
            restored = json.loads(node(SNAPSHOT).stdout)
            assert restored == after, "Rollback failed to restore exact pair/image/users/settings/inodes"
            node("/repo/scripts/familytraffic-security check")
            node("source /repo/scripts/familytraffic-security; security_paths; SECURITY_WORK=$(mktemp -d); security_verify_traffic; security_cleanup")
            result["checks"].append("post-policy injected failure restored exact prior pair/image/managed policy; real authenticated traffic recovered")
            invalid = node(INVALID, check=False)
            assert invalid.returncode == 0, invalid.stderr
            assert json.loads(node(SNAPSHOT).stdout) == restored
            result["checks"].append("incompatible local immutable image refused without changing deployment")
            result["exit_status"] = 0
            print(json.dumps(result, indent=2), flush=True)
    except Exception as error:
        result["exit_status"] = 1
        result["error"] = str(error)
        raise
    finally:
        (artifacts / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        # Every deletion names resources created by this invocation only.
        for kind in ("node", "daemon"):
            run(["docker", "rm", "-f", resources[kind]], check=False)
        for kind in ("data", "certs", "state"):
            run(["docker", "volume", "rm", resources[kind]], check=False)
        run(["docker", "network", "rm", resources["network"]], check=False)
        run(["docker", "image", "rm", resources["image"]], check=False)


SETUP = r'''
mkdir -p /opt/familytraffic/{config/nginx,data,logs/xray,transaction-tmp} /etc/letsencrypt/live/proxy.lab
openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj /CN=proxy.lab -addext 'subjectAltName=DNS:proxy.lab,IP:127.0.0.1' -keyout /etc/letsencrypt/live/proxy.lab/privkey.pem -out /etc/letsencrypt/live/proxy.lab/fullchain.pem >/dev/null 2>&1
cp /etc/letsencrypt/live/proxy.lab/fullchain.pem /usr/local/share/ca-certificates/transaction-lab.crt
update-ca-certificates >/dev/null 2>&1
# The node has no init system. Delegate service-manager reloads to the real daemon.
cat > /usr/local/bin/systemctl <<'SERVICE'
#!/bin/bash
case "$*" in
    'reload fail2ban') exec fail2ban-client reload ;;
    'restart fail2ban') exec fail2ban-client restart ;;
    *) exit 1 ;;
esac
SERVICE
chmod 755 /usr/local/bin/systemctl
printf '[sshd]\nenabled = false\n' > /etc/fail2ban/jail.local
fail2ban-client -x start >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw limit 1080/tcp comment 'VLESS SOCKS5 Proxy (rate-limited)' >/dev/null
ufw --force enable >/dev/null
python3 - <<'PY'
import json,os,pathlib
root=pathlib.Path('/opt/familytraffic')
accounts=[{'user':'transaction-user','pass':'transaction-password'}]
inbounds=[{'tag':'socks5-proxy','listen':'127.0.0.1','port':10800,'protocol':'socks','settings':{'auth':'password','accounts':accounts}}, {'tag':'http-proxy','listen':'127.0.0.1','port':18118,'protocol':'http','settings':{'accounts':accounts}}]
(root/'config/xray_config.json').write_text(json.dumps({'inbounds':inbounds,'outbounds':[{'protocol':'freedom','tag':'direct'}],'routing':{'rules':[{'type':'field','inboundTag':['socks5-proxy','http-proxy'],'source':['127.0.0.1'],'outboundTag':'direct'}]}}))
(root/'data/users.json').write_text(json.dumps({'users':[{'username':'transaction-user','proxy_password':'transaction-password','connection_type':'proxy'}]}))
os.chmod(root/'data/users.json',0o600)
(root/'.env').write_text('DOMAIN=proxy.lab\nPROXY_NOTLS_ENABLED=false\n')
PY
source /repo/lib/nginx_stream_generator.sh
generate_nginx_config proxy.lab false '' '' '' false false | sed '/proxy_protocol on;/d' > /opt/familytraffic/config/nginx/nginx.conf
# A label-only previous image has a different immutable identity and the same protocol support.
docker create --name transaction-previous __IMAGE__ >/dev/null
docker commit --change 'LABEL ft.transaction.previous=true' transaction-previous transaction-previous:local >/dev/null
docker rm transaction-previous >/dev/null
previous=$(docker image inspect --format '{{.Id}}' transaction-previous:local)
cat > /opt/familytraffic/docker-compose.yml <<COMPOSE
services:
  familytraffic:
    image: $previous
    container_name: familytraffic
    network_mode: host
    entrypoint: [/usr/bin/supervisord, -c, /etc/familytraffic/supervisord.conf]
    volumes:
      - /opt/familytraffic/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/familytraffic/config/xray_config.json:/etc/xray/config.json:ro
      - /opt/familytraffic/data/users.json:/etc/xray/users.json:ro
      - /opt/familytraffic/logs/xray:/var/log/xray
      - /etc/letsencrypt:/etc/letsencrypt:ro
COMPOSE
'''

TARGET = """
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import ssl
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.end_headers();self.wfile.write(b'transaction fixture')
    def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',9443),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/etc/letsencrypt/live/proxy.lab/fullchain.pem','/etc/letsencrypt/live/proxy.lab/privkey.pem')
server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()
"""

SNAPSHOT = r'''
python3 - <<'PY'
import hashlib,json,pathlib,subprocess
root=pathlib.Path('/opt/familytraffic')
files=['config/xray_config.json','config/nginx/nginx.conf','.env','data/users.json','docker-compose.security.yml']
result={'image':subprocess.check_output(['docker','inspect','--format','{{.Image}}','familytraffic'],text=True).strip(),'inodes':{},'hashes':{}}
for file in files:
    path=root/file
    result['hashes'][file]=hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    if file in files[:2]:result['inodes'][file]=path.stat().st_ino
result['users']=result['hashes']['data/users.json']
result['override']=(root/'docker-compose.security.yml').read_text() if (root/'docker-compose.security.yml').exists() else ''
result['xray']=(root/'config/xray_config.json').read_text()
result['firewall']=subprocess.check_output(['ufw','status','numbered'],text=True)
result['policy']={}
for file in ['/etc/fail2ban/jail.d/familytraffic-proxy-auth.conf','/etc/fail2ban/filter.d/familytraffic-proxy-auth.conf','/etc/logrotate.d/familytraffic-proxy-auth']:
    path=pathlib.Path(file)
    result['policy'][file]=hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
print(json.dumps(result))
PY
'''

FAULT = r'''
source /repo/scripts/familytraffic-security
original=$(declare -f security_reconcile_policy)
eval "${original/security_reconcile_policy/security_real_policy}"
security_reconcile_policy() { security_real_policy || return 1; return 1; }
export PROXY_NOTLS_ENABLED=true
image=$(docker image inspect --format '{{.Id}}' transaction-previous:local)
security_reconcile "$image"
'''

INVALID = r'''
before=$(sha256sum /opt/familytraffic/config/{xray_config.json,nginx/nginx.conf})
mkdir -p /tmp/empty-root
image=$(tar -C /tmp/empty-root -cf - . | docker import - transaction-invalid:local)
if /repo/scripts/familytraffic-security reconcile --image "$image"; then exit 1; fi
[[ "$before" == "$(sha256sum /opt/familytraffic/config/{xray_config.json,nginx/nginx.conf})" ]]
'''

if __name__ == "__main__":
    main()
