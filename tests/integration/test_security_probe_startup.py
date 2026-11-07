"""Exercise authentication verification while a proxy listener starts late."""

import base64
import datetime
import json
import pathlib
import re
import socket
import subprocess
import tempfile
import threading
import time
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts/familytraffic-security"


class SecurityProbeStartupTest(unittest.TestCase):
    def test_authentication_probe_waits_for_delayed_listener(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            journal = root / "auth.log"
            journal.touch()
            config = {"inbounds": [{"tag": "http-proxy", "settings": {
                "accounts": [{"user": "fixture", "pass": "private-fixture"}]
            }}]}
            (root / "xray.json").write_text(json.dumps(config))
            with socket.socket() as server:
                server.bind(("127.0.0.1", 0))
                port = server.getsockname()[1]
                (root / "probe.curl").write_text(
                    f'proxy = "http://127.0.0.1:{port}"\n'
                    'proxy-user = "fixture:private-fixture"\n'
                )
                errors = []

                def serve():
                    try:
                        # A bound socket refuses connections until listen() runs.
                        time.sleep(0.5)
                        server.listen()
                        server.settimeout(5)
                        connection, peer = server.accept()
                        with connection:
                            connection.settimeout(5)
                            request = b""
                            while b"\r\n\r\n" not in request:
                                chunk = connection.recv(16384)
                                if not chunk:
                                    raise AssertionError("Incomplete proxy request")
                                request += chunk
                            auth = re.search(rb"Proxy-Authorization: Basic ([^\r\n]+)", request)
                            username = base64.b64decode(auth[1]).decode().split(":")[0]
                            timestamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                                "%Y-%m-%dT%H:%M:%SZ"
                            )
                            journal.write_text(
                                f'{timestamp} FT_AUTH_FAILURE protocol=http src={peer[0]} '
                                f'username="{username}" truncated=false\n'
                            )
                            connection.sendall(
                                b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                                b"Content-Length: 0\r\n\r\n"
                            )
                    except Exception as error:
                        errors.append(error)

                thread = threading.Thread(target=serve)
                thread.start()
                try:
                    result = subprocess.run(
                        ["bash", "-c", 'source "$1"; SECURITY_WORK="$2"; '
                         'SECURITY_LOG="$2/auth.log"; SECURITY_XRAY="$2/xray.json"; '
                         'security_verify_auth_event', "test", str(SCRIPT), directory],
                        capture_output=True, text=True, timeout=30,
                    )
                finally:
                    thread.join(timeout=7)
                self.assertFalse(thread.is_alive(), "Proxy fixture did not finish")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(errors, [])
                self.assertNotIn("private-fixture", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
