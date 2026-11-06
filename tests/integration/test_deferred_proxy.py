#!/usr/bin/env python3
"""Verify deferred proxy provisioning against a prebuilt Xray image."""

import http.server
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[2]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class DeferredProxyTest(unittest.TestCase):
    def test_proxies_deny_before_user_and_allow_after_proxy_user(self):
        image = os.environ["FT_TEST_IMAGE"]
        subprocess.run(["docker", "image", "inspect", image], check=True, stdout=subprocess.DEVNULL)
        hits = []

        class Target(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"deferred-proxy-ok")

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Target)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        name = "ft-deferred-test-" + uuid.uuid4().hex[:10]
        with tempfile.TemporaryDirectory(prefix="ft-deferred-test-") as folder:
            directory = pathlib.Path(folder)
            config = directory / "config.json"
            users = directory / "users.json"
            ports = {"http": free_port(), "socks": free_port()}
            config.write_text(json.dumps({
                "inbounds": [
                    {"tag": "http-proxy", "listen": "127.0.0.1", "port": ports["http"],
                     "protocol": "http", "settings": {"accounts": []}},
                    {"tag": "socks5-proxy", "listen": "127.0.0.1", "port": ports["socks"],
                     "protocol": "socks", "settings": {"auth": "password", "accounts": []}},
                ],
                "outbounds": [{"tag": "direct", "protocol": "freedom"},
                              {"tag": "blocked", "protocol": "blackhole"}],
                "routing": {"rules": []},
            }))
            users.write_text('{"users":[]}')
            (directory / "auth.log").touch(mode=0o600)

            def shell(command):
                env = dict(os.environ, XRAY_CONFIG=str(config), USERS_JSON=str(users))
                subprocess.run(["bash", "-euc", command, "_", str(ROOT)], env=env,
                               check=True, stdout=subprocess.DEVNULL)

            def wait_ready():
                for _ in range(100):
                    try:
                        with socket.create_connection(("127.0.0.1", ports["http"]), timeout=0.1):
                            return
                    except OSError:
                        time.sleep(0.05)
                self.fail("Xray did not start")

            def request(protocol, account=None):
                scheme = "http" if protocol == "http" else "socks5h"
                lines = [f'proxy = "{scheme}://127.0.0.1:{ports[protocol]}"']
                if account:
                    lines.append('proxy-user = ' + json.dumps(account["user"] + ":" + account["pass"]))
                curl = directory / "probe.curl"
                curl.write_text("\n".join(lines) + "\n")
                curl.chmod(0o600)
                return subprocess.run(["curl", "--config", str(curl), "--noproxy", "", "--proxytunnel", "--silent",
                                       "--fail", "--max-time", "3",
                                       f"http://127.0.0.1:{server.server_port}/probe"], capture_output=True)

            shell('source "$1/lib/proxy_security.sh"; initialize_pending_proxy_config "$XRAY_CONFIG"; '
                  'validate_saved_proxy_accounts "$XRAY_CONFIG" "$USERS_JSON"')
            lock = json.loads(config.read_text())["inbounds"][0]["settings"]["accounts"][0]
            try:
                subprocess.run(["docker", "run", "-d", "--rm", "--pull", "never", "--name", name,
                                "--network", "host", "--entrypoint", "/usr/bin/xray",
                                "-v", f"{config}:/etc/xray/config.json:ro",
                                "-v", f"{directory}:/var/log/xray", image,
                                "run", "-config", "/etc/xray/config.json"],
                               check=True, stdout=subprocess.DEVNULL)
                wait_ready()
                for protocol in ports:
                    self.assertNotEqual(request(protocol).returncode, 0)
                    response = request(protocol, lock)
                    self.assertNotEqual(response.returncode, 0)
                    self.assertNotEqual(response.stdout, b"deferred-proxy-ok")
                self.assertEqual(hits, [])
                users.write_text('{"users":[{"username":"vpn-only","uuid":"fixture"}]}')
                shell('source "$1/lib/user_management.sh"; rebuild_proxy_accounts_from_users_json; '
                      'proxy_config_is_pending "$XRAY_CONFIG"')
                for protocol in ports:
                    self.assertNotEqual(request(protocol, lock).returncode, 0)
                self.assertEqual(hits, [])
                users.write_text('{"users":[{"username":"alice","proxy_password":"fixture-password"}]}')
                shell('source "$1/lib/user_management.sh"; update_proxy_accounts alice fixture-password; '
                      'validate_saved_proxy_accounts "$XRAY_CONFIG" "$USERS_JSON"')
                subprocess.run(["docker", "restart", name], check=True, stdout=subprocess.DEVNULL)
                wait_ready()
                for protocol in ports:
                    self.assertNotEqual(request(protocol).returncode, 0)
                    self.assertNotEqual(request(protocol, lock).returncode, 0)
                    response = request(protocol, {"user": "alice", "pass": "fixture-password"})
                    self.assertEqual(response.returncode, 0, response.stderr.decode())
                    self.assertEqual(response.stdout, b"deferred-proxy-ok")
                self.assertEqual(len(hits), 2)
            finally:
                subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
