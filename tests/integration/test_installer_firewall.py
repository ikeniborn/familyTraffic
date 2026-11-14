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
            "source /repo/lib/installer_security.sh\ncurrent_ssh_connection() { :; }\nunset SSH_CONNECTION\n" + script,
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

    def test_duplicate_allow_behind_deny_is_reordered(self):
        output = self.node("""
ufw deny 22/tcp
ufw allow from 198.51.100.7 to any port 22 proto tcp
configure_install_firewall 198.51.100.7
ufw status | grep -qx 'Status: active'
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

    def test_existing_global_ssh_deny_is_preserved_after_allow(self):
        output = self.node("""
ufw deny 22/tcp
configure_install_firewall ''
ufw status | grep -qx 'Status: active'
ufw show added
""")
        self.assertIn("ufw deny 22/tcp", output)

    def test_empty_and_single_family_rule_lists(self):
        for seed, source in [("", "203.0.113.7"), ("", "2001:db8::7"), ("", ""),
                             ("ufw allow from 2001:db8::1 to any port 443 proto tcp", "203.0.113.7"),
                             ("ufw allow from 203.0.113.1 to any port 443 proto tcp", "2001:db8::7")]:
            with self.subTest(seed=seed, source=source):
                self.node(f"""
sed -i s/IPV6=no/IPV6=yes/ /etc/default/ufw
{seed}
configure_install_firewall '{source}'
ufw status | grep -qx 'Status: active'
verify_ssh_firewall_rules '{source}' 22
cp /etc/ufw/user.rules /tmp/first4
cp /etc/ufw/user6.rules /tmp/first6
configure_install_firewall '{source}'
cmp /tmp/first4 /etc/ufw/user.rules
cmp /tmp/first6 /etc/ufw/user6.rules
""")

    def test_active_conflicts_preserve_unrelated_rules_and_are_idempotent(self):
        for action in ("deny", "reject", "limit"):
            with self.subTest(action=action):
                self.node(f"""
ufw {action} 22/tcp
ufw allow from 203.0.113.7 to any port 22 proto tcp
ufw allow 443/tcp comment 'operator HTTPS'
ufw deny 8443/tcp
ufw allow out 123/udp
ufw route deny 8080/tcp
ufw --force enable
iptables -S ufw-user-output > /tmp/output
iptables -S ufw-user-forward > /tmp/forward
SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 2222' configure_install_firewall 203.0.113.7
iptables -S ufw-user-input | grep '^-A ' > /tmp/first
ufw show added > /tmp/added
SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 2222' configure_install_firewall 203.0.113.7
iptables -S ufw-user-input | grep '^-A ' > /tmp/second
cmp /tmp/first /tmp/second
ufw show added > /tmp/again
cmp /tmp/added /tmp/again
grep -q 'operator HTTPS' /tmp/added
grep -q 'ufw deny 8443/tcp' /tmp/added
iptables -S ufw-user-output > /tmp/output-after
iptables -S ufw-user-forward > /tmp/forward-after
cmp /tmp/output /tmp/output-after
cmp /tmp/forward /tmp/forward-after
test "$(head -1 /tmp/first)" = '-A ufw-user-input -s 198.51.100.7/32 -p tcp -m tcp --dport 2222 -j ACCEPT'
""")

    def test_failed_live_apply_restores_both_families_and_saved_files(self):
        self.node("""
sed -i s/IPV6=no/IPV6=yes/ /etc/default/ufw
ufw allow 443/tcp
ufw --force enable
iptables -S ufw-user-input > /tmp/before4
ip6tables -S ufw6-user-input > /tmp/before6
cp /etc/ufw/user.rules /tmp/before.rules
cp /etc/ufw/user6.rules /tmp/before6.rules
mkdir /tmp/inject
cat > /tmp/inject/sitecustomize.py <<'PY'
import pathlib,subprocess
original=subprocess.run
def run(args,*a,**kw):
    if args[0].endswith('/ip6tables-restore') and '--test' not in args and not pathlib.Path('/tmp/injected').exists():
        pathlib.Path('/tmp/injected').touch()
        raise subprocess.CalledProcessError(1,args)
    return original(args,*a,**kw)
subprocess.run=run
PY
if PYTHONPATH=/tmp/inject configure_install_firewall ''; then exit 99; fi
test -e /tmp/injected
iptables -S ufw-user-input > /tmp/after4
ip6tables -S ufw6-user-input > /tmp/after6
cmp /tmp/before4 /tmp/after4
cmp /tmp/before6 /tmp/after6
cmp /tmp/before.rules /etc/ufw/user.rules
cmp /tmp/before6.rules /etc/ufw/user6.rules
ufw status | grep -qx 'Status: active'
""")

    def test_disabled_ipv6_rejects_ipv6_before_changing_rules(self):
        self.node("""
ufw allow 443/tcp
cp /etc/ufw/user.rules /tmp/before
if configure_install_firewall 2001:db8::7; then exit 99; fi
cmp /tmp/before /etc/ufw/user.rules
ufw status | grep -qx 'Status: inactive'
""")

    def test_invalid_management_port_does_not_change_rules(self):
        self.node("""
cp /etc/ufw/user.rules /tmp/before
if SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 65536' configure_install_firewall 203.0.113.7; then exit 99; fi
cmp /tmp/before /etc/ufw/user.rules
ufw status | grep -qx 'Status: inactive'
""")

    def test_ipv6_conflict_and_ipv4_management_session(self):
        self.node("""
sed -i s/IPV6=no/IPV6=yes/ /etc/default/ufw
ufw reject from 2001:db8::7 to any port 22 proto tcp
ufw allow from 2001:db8::7 to any port 22 proto tcp
ufw deny 22/tcp
ufw --force enable
SSH_CONNECTION='198.51.100.7 50000 192.0.2.1 2222' configure_install_firewall 2001:db8::7
verify_ssh_firewall_rules 2001:db8::7 22
verify_ssh_firewall_rules 198.51.100.7 2222
ip6tables -C ufw6-user-input -s 2001:db8::7/128 -p tcp --dport 22 -j ACCEPT
""")

    def test_write_failure_restores_files_without_activation(self):
        self.node("""
sed -i s/IPV6=no/IPV6=yes/ /etc/default/ufw
cp /etc/ufw/user.rules /tmp/before.rules
cp /etc/ufw/user6.rules /tmp/before6.rules
mkdir /tmp/inject
cat > /tmp/inject/sitecustomize.py <<'PY'
import os,pathlib
original=os.replace
def replace(src,dst):
    if str(dst)=='/etc/ufw/user6.rules' and not pathlib.Path('/tmp/injected').exists():
        pathlib.Path('/tmp/injected').touch()
        raise OSError('injected second-family persistence failure')
    return original(src,dst)
os.replace=replace
PY
if PYTHONPATH=/tmp/inject configure_install_firewall ''; then exit 99; fi
cmp /tmp/before.rules /etc/ufw/user.rules
cmp /tmp/before6.rules /etc/ufw/user6.rules
test -e /tmp/injected
ufw status | grep -qx 'Status: inactive'
""")

    def test_raw_persistent_and_live_only_rules_are_preserved(self):
        self.node("""
ufw allow 443/tcp
ufw --force enable
sed -i -e '/### RULES ###/a -A ufw-user-input -p tcp --dport 8443 -j ACCEPT' -e '/### RULES ###/a -A ufw-user-input -p tcp --dport 8444 -j DROP' /etc/ufw/user.rules
iptables -A ufw-user-input -p tcp --dport 8443 -j ACCEPT
iptables -A ufw-user-input -p tcp --dport 8444 -j DROP
iptables -I ufw-user-input 1 -p tcp --dport 8553 -j ACCEPT
iptables -I ufw-user-input 2 -p tcp --dport 8554 -j DROP
configure_install_firewall 203.0.113.7
iptables -C ufw-user-input -p tcp --dport 8443 -j ACCEPT
iptables -C ufw-user-input -p tcp --dport 8444 -j DROP
iptables -C ufw-user-input -p tcp --dport 8553 -j ACCEPT
iptables -C ufw-user-input -p tcp --dport 8554 -j DROP
grep -qx -- '-A ufw-user-input -p tcp --dport 8443 -j ACCEPT' /etc/ufw/user.rules
grep -qx -- '-A ufw-user-input -p tcp --dport 8444 -j DROP' /etc/ufw/user.rules
""")

    def test_inactive_activation_retains_raw_rules_across_reload(self):
        self.node("""
printf '# café\\n' >> /etc/ufw/user.rules
printf '# IPv6 café\\n' >> /etc/ufw/user6.rules
chmod 640 /etc/ufw/user.rules
sed -i '/### RULES ###/a -A ufw-user-input -p tcp --dport 8443 -j DROP' /etc/ufw/user.rules
configure_install_firewall 203.0.113.7
grep -qx -- '-A ufw-user-input -p tcp --dport 8443 -j DROP' /etc/ufw/user.rules
grep -qx '# café' /etc/ufw/user.rules
grep -qx '# IPv6 café' /etc/ufw/user6.rules
test "$(stat -c %a /etc/ufw/user.rules)" = 640
ufw reload
iptables -C ufw-user-input -p tcp --dport 8443 -j DROP
""")

    def test_native_ufw_edits_do_not_duplicate_managed_grants(self):
        self.node("""
configure_install_firewall 203.0.113.7
ufw allow 443/tcp
ufw show added > /tmp/first
configure_install_firewall 203.0.113.7
ufw show added > /tmp/second
cmp /tmp/first /tmp/second
""")

    def test_activation_recovery_attempts_both_families_after_one_write_fails(self):
        self.node("""
printf '# IPv6 café\\n' >> /etc/ufw/user6.rules
mkdir /tmp/inject
cat > /tmp/inject/sitecustomize.py <<'PY'
import os,pathlib
from ufw.frontend import UFWFrontend
original_enable=UFWFrontend.set_enabled
original_replace=os.replace
def enable(self,value):
    result=original_enable(self,value)
    pathlib.Path('/tmp/activated').touch()
    return result
def replace(src,dst):
    if pathlib.Path('/tmp/activated').exists():
        if str(dst)=='/etc/ufw/user.rules':
            raise OSError('injected IPv4 activation recovery failure')
        if str(dst)=='/etc/ufw/user6.rules':
            pathlib.Path('/tmp/restored6').touch()
    return original_replace(src,dst)
UFWFrontend.set_enabled=enable
os.replace=replace
PY
if PYTHONPATH=/tmp/inject configure_install_firewall 203.0.113.7; then exit 99; fi
test -e /tmp/restored6
grep -qx '# IPv6 café' /etc/ufw/user6.rules
""")


if __name__ == "__main__":
    unittest.main()
