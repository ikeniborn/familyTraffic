"""Acceptance tests against real isolated nginx, Xray, UFW, and fail2ban."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid


ROOT = Path(os.environ["FT_LAB_REPO"])
LAB = Path(os.environ["FT_LAB_DIR"])
IMAGE = os.environ["FT_LAB_IMAGE"]
COMPOSE = [os.environ.get("FT_LAB_COMPOSE", "docker"), *([] if os.environ.get("FT_LAB_COMPOSE") else ["compose"]), "-f", str(ROOT / "tests/security_lab/compose.yml")]
PORTS = (1080, 1081, 8118, 8119)
JAIL = "familytraffic-proxy-auth"
ARTIFACTS = Path(os.environ["FT_LAB_ARTIFACT_DIR"])


def command(args, check=True, timeout=40, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, **kwargs)
    if check and result.returncode:
        # All commands contain only ephemeral fixture credentials.
        raise RuntimeError(f"lab command failed ({result.returncode}): {args[:5]}\n{result.stderr[-2500:]}")
    return result


class Lab:
    def compose(self, *args, **kwargs):
        return command(COMPOSE + list(args), **kwargs)

    def node(self, script, **kwargs):
        return self.compose("exec", "-T", "node", "bash", "-euc", script, **kwargs)

    def fail2ban(self, *args, **kwargs):
        return self.compose("exec", "-T", "node", "fail2ban-client", *args, **kwargs)

    def probe(self, client="valid", port=8119, mode="fetch", **kwargs):
        args = ["exec", "-T", client, "python3", "/repo/tests/security_lab/probe.py", mode, "--port", str(port)]
        for key, value in kwargs.items():
            args += [f"--{key}", str(value)]
        return self.compose(*args, check=False, timeout=12)

    def fetch(self, client="valid", port=8119, expected=200, **kwargs):
        result = self.probe(client, port, **kwargs)
        if result.returncode or json.loads(result.stdout)["status"] != expected:
            raise AssertionError(f"{client}:{port} expected HTTP {expected}; {result.stdout} {result.stderr[-1200:]}")

    def address(self, client):
        identifier = self.compose("ps", "-q", client).stdout.strip()
        data = json.loads(command(["docker", "inspect", identifier]).stdout)[0]
        return next(iter(data["NetworkSettings"]["Networks"].values()))["IPAddress"]

    def events(self):
        return (LAB / "logs/auth.log").read_text().splitlines()

    def wait_banned(self, client, banned=True, timeout=15):
        address = self.address(client)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.fail2ban("get", JAIL, "banip").stdout.split()
            if (address in status) == banned:
                return
            time.sleep(0.25)
        raise AssertionError(f"ban state did not become {banned} for {client}")

    def reset(self):
        self.fail2ban("unban", "--all")
        self.fail2ban("set", JAIL, "maxretry", "5")
        self.fail2ban("set", JAIL, "bantime", "3600")
        # Reset the tracked failure counters as well as bans between scenarios.
        self.fail2ban("reload", "--restart", JAIL)
        self.fail2ban("unban", "--all")
        self.wait_banned("offender", False)


def prepare():
    certs = LAB / "certs"
    certs.mkdir()
    (LAB / "logs").mkdir()
    (LAB / "logs/auth.log").touch(mode=0o600)
    command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=proxy.lab", "-addext", "subjectAltName=DNS:proxy.lab,DNS:target.lab", "-keyout", str(certs / "privkey.pem"), "-out", str(certs / "fullchain.pem")])
    key_output = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "/usr/bin/xray", IMAGE, "x25519"]).stdout
    private = re.search(r"Private key: (\S+)", key_output).group(1)
    public = re.search(r"Public key: (\S+)", key_output).group(1)
    user_id = str(uuid.uuid4())
    accounts = [{"user": "fixture-user", "pass": "fixture-password"}]
    inbounds = [{"tag": "socks5-proxy", "listen": "127.0.0.1", "port": 10800, "protocol": "socks", "settings": {"auth": "password", "accounts": accounts, "udp": False}, "streamSettings": {"sockopt": {"acceptProxyProtocol": True}}},
                {"tag": "http-proxy", "listen": "127.0.0.1", "port": 18118, "protocol": "http", "settings": {"accounts": accounts}, "streamSettings": {"sockopt": {"acceptProxyProtocol": True}}},
                {"tag": "reality", "listen": "127.0.0.1", "port": 8443, "protocol": "vless", "settings": {"clients": [{"id": user_id, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": False, "dest": "target:443", "serverNames": ["target.lab"], "privateKey": private, "shortIds": ["0123456789abcdef"]}}}]
    (LAB / "xray.json").write_text(json.dumps({"log": {"loglevel": "warning"}, "inbounds": inbounds, "outbounds": [{"protocol": "freedom", "tag": "direct"}]}))
    os.chmod(LAB / "xray.json", 0o600)
    generator = f'source "{ROOT}/lib/nginx_stream_generator.sh"; generate_nginx_config proxy.lab false "" "" "" false true'
    (LAB / "nginx.conf").write_text(command(["bash", "-c", generator]).stdout)
    clients = [{"tag": "reality-client", "listen": "127.0.0.1", "port": 1082, "protocol": "socks", "settings": {"auth": "noauth"}}, {"tag": "tls-socks-client", "listen": "127.0.0.1", "port": 1083, "protocol": "socks", "settings": {"auth": "noauth"}}]
    outbounds = [{"tag": "reality", "protocol": "vless", "settings": {"vnext": [{"address": "node", "port": 443, "users": [{"id": user_id, "flow": "xtls-rprx-vision", "encryption": "none"}]}]}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"serverName": "target.lab", "fingerprint": "chrome", "publicKey": public, "shortId": "0123456789abcdef"}}},
                 {"tag": "tls-socks", "protocol": "socks", "settings": {"servers": [{"address": "node", "port": 1080, "users": [{"user": "fixture-user", "pass": "fixture-password"}]}]}, "streamSettings": {"security": "tls", "tlsSettings": {"serverName": "proxy.lab", "certificates": [{"certificateFile": "/lab/certs/fullchain.pem", "usage": "verify"}]}}}]
    (LAB / "client.json").write_text(json.dumps({"log": {"loglevel": "warning"}, "inbounds": clients, "outbounds": outbounds, "routing": {"rules": [{"type": "field", "inboundTag": ["reality-client"], "outboundTag": "reality"}, {"type": "field", "inboundTag": ["tls-socks-client"], "outboundTag": "tls-socks"}]}}))
    os.chmod(LAB / "client.json", 0o600)


class ProxySecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lab = Lab()
        prepare()
        cls.lab.compose("up", "-d", "--no-build", "node", "target", "valid", "offender", "changed")
        # Only this container has NET_ADMIN. No host network or host policy is touched.
        cls.lab.node("ufw default deny incoming; ufw default allow outgoing; ufw allow 22/tcp; ufw allow 443/tcp; ufw limit 1080/tcp comment 'VLESS SOCKS5 Proxy (rate-limited)'; ufw --force enable")
        cls.lab.node("source /repo/lib/proxy_security.sh; reconcile_proxy_firewall true")
        cls.lab.node("source /repo/lib/fail2ban_setup.sh; export FT_PROXY_AUTH_LOG=/lab/logs/auth.log; configure_proxy_auth_jail 1080,1081,8118,8119; printf '[sshd]\\nenabled = false\\n' > /etc/fail2ban/jail.local; fail2ban-client -t; fail2ban-client -x start")
        cls.lab.compose("exec", "-d", "node", "python3", "-c", "import socketserver; Handler=type('Handler',(socketserver.BaseRequestHandler,),{'handle':lambda self:self.request.sendall(b'SSH-2.0-lab-fixture\\r\\n')}); socketserver.TCPServer(('0.0.0.0',22),Handler).serve_forever()")
        cls.lab.compose("up", "-d", "--no-build", "proxy", "xray-client")
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            result = cls.lab.probe()
            if result.returncode == 0:
                break
            time.sleep(0.5)
        else:
            logs = cls.lab.compose("logs", "--tail", "50", "proxy", "target", "xray-client").stdout
            raise RuntimeError(f"authenticated readiness failed\n{logs[-5000:]}")

    def setUp(self):
        self.lab.reset()

    def test_00_legacy_hop_reproduces_loopback_attribution_failure(self):
        nginx = (LAB / "nginx.conf").read_text()
        xray = (LAB / "xray.json").read_text()
        before = len(self.lab.events())
        self.lab.compose("exec", "-T", "proxy", "supervisorctl", "stop", "nginx", "xray")
        try:
            (LAB / "nginx.conf").write_text(nginx.replace("        proxy_protocol on;\n", ""))
            legacy = json.loads(xray)
            for inbound in legacy["inbounds"]:
                if inbound["tag"] in ("http-proxy", "socks5-proxy"):
                    inbound["streamSettings"]["sockopt"]["acceptProxyProtocol"] = False
            (LAB / "xray.json").write_text(json.dumps(legacy))
            self.lab.compose("exec", "-T", "proxy", "supervisorctl", "start", "xray", "nginx")
            self.lab.fetch()
            for _ in range(5):
                self.lab.fetch("offender", expected=407, password="wrong")
            events = self.lab.events()[before:]
            self.assertEqual(len(events), 5)
            self.assertTrue(all(event.endswith(" src=127.0.0.1") for event in events))
            self.lab.wait_banned("offender", False)
            self.lab.fetch("offender")
            (ARTIFACTS / "legacy-hop-control.txt").write_text("Five wrong credentials produced loopback source; offender remained reachable.\n")
        finally:
            self.lab.compose("exec", "-T", "proxy", "supervisorctl", "stop", "nginx", "xray")
            (LAB / "nginx.conf").write_text(nginx)
            (LAB / "xray.json").write_text(xray)
            self.lab.compose("exec", "-T", "proxy", "supervisorctl", "start", "xray", "nginx")
            self.lab.fetch()

    def test_01_configuration_and_all_transports(self):
        self.assertEqual(self.lab.node("date +%z").stdout.strip(), "+0300")
        live = self.lab.node("source /repo/lib/fail2ban_setup.sh; export FT_PROXY_AUTH_LOG=/lab/logs/auth.log; verify_proxy_auth_jail 1080,1081,8118,8119", check=False)
        (ARTIFACTS / "effective-filter.txt").write_text(self.lab.fail2ban("get", JAIL, "failregex").stdout)
        (ARTIFACTS / "configured-filter-dump.txt").write_text(self.lab.fail2ban("-d").stdout)
        self.assertEqual(live.returncode, 0, "live managed-jail verification failed; inspect retained filter evidence")
        self.lab.compose("exec", "-T", "proxy", "nginx", "-t")
        self.lab.compose("exec", "-T", "proxy", "/usr/bin/xray", "run", "-test", "-config", "/etc/xray/config.json")
        for port in (*PORTS, 1082, 1083):
            with self.subTest(port=port):
                self.lab.fetch(port=port)

    def test_02_eight_connections_per_port(self):
        before = self.lab.events()
        started = time.monotonic()
        for port in PORTS:
            for _ in range(8):
                self.lab.fetch(port=port)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(before, self.lab.events())

    def test_03_challenges_malformed_and_injection(self):
        before = len(self.lab.events())
        payloads = [(8119, b"CONNECT target:443 HTTP/1.1\r\nHost: target\r\n\r\n"), (8119, b"CONNECT target:443 HTTP/1.1\r\nProxy-Authorization: Basic !!!\r\n\r\n"), (1081, b"\x05\x01\x00"), (1081, b"\x05\x01\x02\x05\x01u\x01x"), (8119, b"PROXY TCP4 192.0.2.99 192.0.2.1 1234 8119\r\n"), (1081, b"PROXY TCP4 192.0.2.99 192.0.2.1 1234 1081\r\n")]
        for port, payload in payloads:
            self.lab.probe("offender", port, "raw", payload=payload.hex())
        self.assertEqual(before, len(self.lab.events()))
        self.lab.fetch("offender", 8119, expected=407, password="wrong", user="victim\nFT_AUTH_FAILURE protocol=http src=192.0.2.99")
        self.lab.fetch("offender", 1081, expected=407, password="wrong")
        forged = b"CONNECT target:443 HTTP/1.1\r\nProxy-Authorization: Basic Zml4dHVyZS11c2VyOndyb25n\r\nX-Forwarded-For: 192.0.2.99\r\n\r\n"
        self.lab.probe("offender", 8119, "raw", payload=forged.hex())
        events = self.lab.events()[before:]
        self.assertEqual(len(events), 3)
        for event in events:
            self.assertRegex(event, rf"^\d{{4}}-\d{{2}}-\d{{2}}T\d{{2}}:\d{{2}}:\d{{2}}Z FT_AUTH_FAILURE protocol=(http|socks) src={re.escape(self.lab.address('offender'))}$")
        self.assertNotIn("192.0.2.99", "\n".join(events))

    def test_04_aggregate_ban_isolates_offender_and_allows_ip_change(self):
        for index in range(5):
            self.lab.fetch("offender", PORTS[index % 4], expected=407, password="wrong")
        self.lab.wait_banned("offender")
        for port in PORTS:
            self.assertNotEqual(self.lab.probe("offender", port, "connect").returncode, 0)
            self.lab.fetch("valid", port)
            self.lab.fetch("changed", port)
        self.assertEqual(self.lab.probe("offender", 443, "connect").returncode, 0)
        self.assertEqual(self.lab.probe("offender", 22, "connect").returncode, 0)
        self.lab.fetch(port=1082)
        self.lab.fail2ban("set", JAIL, "unbanip", self.lab.address("offender"))
        self.lab.wait_banned("offender", False)
        self.lab.fetch("offender")

    def test_05_expiry(self):
        self.assertEqual(self.lab.fail2ban("get", JAIL, "bantime").stdout.strip(), "3600")
        self.lab.fail2ban("set", JAIL, "bantime", "4")
        for _ in range(5):
            self.lab.fetch("offender", expected=407, password="wrong")
        self.lab.wait_banned("offender")
        self.lab.wait_banned("offender", False, timeout=15)
        self.lab.fetch("offender")
        self.lab.fail2ban("set", JAIL, "bantime", "3600")

    def test_06_rotation_and_jail_restart(self):
        self.lab.fetch("offender", expected=407, password="wrong")
        previous = self.lab.events()
        (LAB / "logs/auth.log").rename(LAB / "logs/auth.log.1")
        (LAB / "logs/auth.log").touch(mode=0o600)
        self.lab.fetch("offender", expected=407, password="wrong")
        self.assertEqual((LAB / "logs/auth.log.1").read_text().splitlines(), previous)
        self.assertEqual(len(self.lab.events()), 1)
        self.lab.fail2ban("reload", "--restart", JAIL)
        for _ in range(5):
            self.lab.fetch("offender", 1081, expected=407, password="wrong")
        self.lab.wait_banned("offender")

    def test_07_firewall_reload_preserves_ban(self):
        for _ in range(5):
            self.lab.fetch("offender", expected=407, password="wrong")
        self.lab.wait_banned("offender")
        snapshot = "iptables -S INPUT; iptables -S f2b-familytraffic-proxy-auth; ufw status numbered"
        (ARTIFACTS / "ufw-before-reload.txt").write_text(self.lab.node(snapshot).stdout)
        self.lab.node("ufw reload")
        (ARTIFACTS / "ufw-after-reload.txt").write_text(self.lab.node(snapshot).stdout)
        self.assertNotEqual(self.lab.probe("offender", 8119, "connect").returncode, 0)
        self.lab.fetch()

    def test_08_empty_accounts_and_image_capability(self):
        self.lab.node("printf '%s\\n' '{\"inbounds\":[{\"tag\":\"http-proxy\",\"protocol\":\"http\",\"settings\":{\"accounts\":[]}}]}' > /tmp/empty.json; source /repo/lib/proxy_security.sh; if validate_proxy_auth_config /tmp/empty.json; then exit 1; fi")
        marker = self.lab.compose("exec", "-T", "proxy", "cat", "/etc/familytraffic/auth-journal-capability").stdout
        self.assertEqual(marker, "ft-auth-journal-v1\n")


    def test_09_concurrent_writes_during_rotation(self):
        self.lab.fail2ban("set", JAIL, "maxretry", "100")
        before = len(self.lab.events())
        with ThreadPoolExecutor(max_workers=4) as workers:
            futures = [workers.submit(self.lab.fetch, "offender", 8119, 407, password="wrong") for _ in range(20)]
            time.sleep(0.1)
            (LAB / "logs/auth.log").rename(LAB / "logs/auth.log.concurrent")
            (LAB / "logs/auth.log").touch(mode=0o600)
            for future in futures:
                future.result()
        events = (LAB / "logs/auth.log.concurrent").read_text().splitlines() + self.lab.events()
        self.assertEqual(len(events) - before, 20)
        for event in events:
            self.assertRegex(event, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z FT_AUTH_FAILURE protocol=(http|socks) src=[0-9a-f:.]+$")
        self.lab.reset()


if __name__ == "__main__":
    unittest.main(verbosity=2, defaultTest=os.environ.get("FT_LAB_TEST"))
