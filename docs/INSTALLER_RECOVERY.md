# Installer firewall and deferred proxy setup

## SSH and UFW

The installer requests a numeric SSH source IP or CIDR for TCP port 22.
An empty answer permits any address. `FT_SSH_ALLOW_FROM` supplies the same choice
for unattended installation; an explicitly empty value permits any address.

Existing UFW rules remain in place. The installer adds SSH permissions before
enabling an inactive firewall. It also preserves the current SSH management
source and port, including when sudo removed `SSH_CONNECTION` from its environment.
Existing broader permissions remain broader; a new source choice does not remove them.

UFW can skip insertion when a similar rule already exists. The installer checks
the resulting rule order. If a preceding rule still blocks the requested SSH
source, installation stops before activating UFW. Review that operator policy
before retrying. The installer does not reset UFW or delete legacy port rules.

```bash
sudo env FT_SSH_ALLOW_FROM=192.0.2.7 ./install.sh
sudo env FT_SSH_ALLOW_FROM= ./install.sh
```

## Proxy users after installation

Selecting public proxies still configures TLS, nginx listeners, private Xray
receivers, UFW, and authentication monitoring. Installation no longer requires
the first user. The selected TLS and no-TLS modes are preserved.

Until a proxy-enabled user exists, a private setup credential keeps authentication
enabled and a first routing rule blocks both proxy receivers through the blackhole
outbound. This credential is not a saved user and is not exported as a client
configuration. Empty HTTP accounts are never used as an enabled proxy configuration.

Create users after installation and choose VPN, proxy, or both:

```bash
sudo familytraffic add-user alice
```

A VPN-only user receives no proxy password and leaves the setup lock in place.
The first proxy-enabled user replaces the private setup credential and removes
the blocking rule. Proxy service then accepts that user's credentials without
reinstallation. Anonymous requests remain rejected.

`FT_INITIAL_PROXY_USERNAME` remains supported for explicit unattended provisioning.
Removing the last proxy-enabled user is permitted. The removal transaction restores
the closed setup state before committing the empty users database. Anonymous and
previous credentials cannot reach proxy destinations. A later proxy-enabled user
reactivates access. Failed application or persistence restores the previous user
and configuration. Concurrent removals are serialized and can remove every user.

## Journal-only hosts

Some Debian hosts enable the sshd Fail2ban jail without `/var/log/auth.log`.
When the effective SSH backend is `auto` and its log path is the standard auth
log, installation writes `jail.d/familytraffic-sshd.local` with `backend = systemd`.
Fail2ban's own parser resolves distribution includes and backend substitutions.
Custom backends and custom log paths remain unchanged.

## Recover an incomplete deployment

Preserve existing users, keys, configurations, and recovery backups. Do not rerun
fresh installation against an existing users database. Use the security reconciler
with the immutable identity of a reviewed local image.

```bash
sudo fail2ban-client -t
read -r -p "Reviewed local image ID: " reviewed_image_id
sudo familytraffic-security reconcile --image "$reviewed_image_id"
sudo familytraffic-security check
sudo familytraffic status
```

A recovery is verified only after a new SSH connection, healthy container state, security inspection,
and unchanged saved identity hashes.

The controlled authentication probe retries connection refusal during container
startup. It still requires an HTTP 407 response and a fresh matching journal
event. A listener that is not ready must not cause immediate deployment rollback.

Run the delayed-listener regression without Docker:

```bash
python3 tests/integration/test_security_probe_startup.py
```

## Focused verification

Use existing local application and test-node images. The integration tests create
only disposable containers. UFW runs in a separate network namespace.

```bash
bats tests/unit/test_installer_security_setup.bats tests/unit/test_pending_proxy_setup.bats tests/unit/test_proxy_fail2ban.bats
FT_TEST_IMAGE=familytraffic:proxy-auth-username python3 tests/integration/test_deferred_proxy.py
FT_UFW_TEST_IMAGE=familytraffic-security-node:local python3 tests/integration/test_installer_firewall.py
```

## Fail2ban trusted addresses

The installer accepts space-separated numeric IPv4/IPv6 addresses and CIDRs for SSH and proxy authentication exclusions. Set `FT_FAIL2BAN_ALLOWLIST` for noninteractive input. Empty input preserves existing exclusions. New entries extend each jail's current exclusions; repeated installations preserve them.

The installer stores exclusions in `/etc/fail2ban/jail.d/zz-familytraffic-allowlist.local`. This setting does not grant firewall access. Existing ban thresholds remain unchanged. Invalid addresses are rejected before this file is written.
