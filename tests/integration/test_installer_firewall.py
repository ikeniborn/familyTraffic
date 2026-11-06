#!/usr/bin/env python3
"""Exercise real UFW in disposable namespaces without host firewall access."""

import os
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class InstallerFirewallTest(unittest.TestCase):
    def node(self, script):
        image = os.environ["FT_UFW_TEST_IMAGE"]
        subprocess.run(["docker", "image", "inspect", image], check=True, stdout=subprocess.DEVNULL)
        result = subprocess.run([
            "docker", "run", "--rm", "--pull", "never", "--cap-add", "NET_ADMIN", "--network", "none",
            "-v", f"{ROOT}:/repo:ro", image, "bash", "-euc",
            "source /repo/lib/installer_security.sh\n" + script,
        ], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_management_allow_precedes_existing_deny(self):
        output = self.node("""
ufw deny 22/tcp
ufw allow 443/tcp
SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 22' configure_install_firewall 203.0.113.7
ufw status | grep -q '^Status: active$'
iptables -S ufw-user-input
""")
        rules = [line for line in output.splitlines() if line.startswith("-A ")]
        self.assertIn("198.51.100.7", rules[0])
        self.assertIn("203.0.113.7", rules[1])
        self.assertIn("--dport 22 -j DROP", rules[2])
        self.assertIn("--dport 443 -j ACCEPT", rules[3])

    def test_duplicate_allow_behind_deny_refuses_activation(self):
        output = self.node("""
ufw deny 22/tcp
ufw allow from 198.51.100.7 to any port 22 proto tcp
if configure_install_firewall 198.51.100.7; then exit 99; fi
ufw status | grep -qx 'Status: inactive'
ufw show added
""")
        self.assertIn("ufw deny 22/tcp", output)
        self.assertIn("198.51.100.7", output)

    def test_empty_source_allows_any_address(self):
        output = self.node("""
ufw allow 443/tcp
configure_install_firewall ''
iptables -S ufw-user-input
""")
        rules = [line for line in output.splitlines() if line.startswith("-A ")]
        self.assertNotIn(" -s ", rules[0])
        self.assertIn("--dport 22 -j ACCEPT", rules[0])
        self.assertIn("--dport 443 -j ACCEPT", rules[1])

    def test_existing_global_ssh_deny_is_preserved_without_activation(self):
        output = self.node("""
ufw deny 22/tcp
if configure_install_firewall ''; then exit 99; fi
ufw status | grep -qx 'Status: inactive'
ufw show added
""")
        self.assertIn("ufw deny 22/tcp", output)


if __name__ == "__main__":
    unittest.main()
