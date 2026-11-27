# Installer firewall and deferred proxy setup

## Recover the selected services

Keep the deployment's `.env`, nginx configuration, Xray configuration, user database and keys together.
The `FT_SERVICE_MODE` value and the five `FT_*_PORT` fields describe the selected external services. Empty port fields disable individual endpoints.
A proxy-only installation has no Reality keys. A healthy proxy with no users has a private setup account and a blocking route.

When a port is occupied, identify its owner and select a free public port in the fresh-install wizard.
For an existing deployment, use the installed management commands. They resolve legacy settings from the saved flags, listeners and receivers.
If those sources disagree, inspect the reported field and restore a matching backup before retrying a configuration change.



## SSH and UFW

The installer accepts one trusted IPv4 or IPv6 address or CIDR. This source can
reach all inbound host ports over all protocols in its address family. Leave the
field empty to allow TCP port 22 from any address. For unattended installation,
set `FT_SSH_ALLOW_FROM` to the trusted source or to an empty string for the SSH default.

The installer also preserves the current SSH peer on its actual TCP port, including
when sudo removed `SSH_CONNECTION` from its environment. It places these managed
permissions before existing blocking rules. Existing service and operator rules
remain in place. Repeating setup with the same source does not duplicate the grant.

For an active firewall, each affected address family's input chain is replaced
in one iptables-restore transaction. Output and forwarding chains remain unchanged.
The installer retains current live rules, including entries added outside UFW.
It validates both replacements before applying either one. If writing
or applying rules fails, it restores the saved files and previous live input rules.
IPv4 and IPv6 replacements are separate transactions with recovery on failure.
An inactive firewall is enabled only after the requested inbound permissions pass
verification. Invalid input or an application failure still stops installation;
ordinary existing-rule conflicts are resolved automatically.

The installer does not reset or disable UFW or delete legacy port rules.

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
