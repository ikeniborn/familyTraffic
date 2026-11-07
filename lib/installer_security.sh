#!/usr/bin/env bash

# Accept only numeric addresses and CIDRs before passing a source to UFW.
validate_ssh_source() {
    [[ -z "$1" ]] && return 0
    python3 - "$1" <<'PY'
import ipaddress,sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
PY
}

prompt_ssh_source() {
    if [[ ${FT_SSH_ALLOW_FROM+x} ]]; then
        SSH_ALLOW_FROM="$FT_SSH_ALLOW_FROM"
        validate_ssh_source "$SSH_ALLOW_FROM" || { echo 'Invalid SSH source address' >&2; return 1; }
    else
        while true; do
            read -r -p 'SSH source IP or CIDR for port 22 (empty = any address): ' SSH_ALLOW_FROM || return 1
            validate_ssh_source "$SSH_ALLOW_FROM" && break
            echo 'Enter a numeric IPv4/IPv6 address or CIDR, or leave empty.' >&2
        done
    fi
    export SSH_ALLOW_FROM
}

# Sudo can remove SSH_CONNECTION. Recover it from the invoking process ancestry.
current_ssh_connection() {
    python3 - <<'PY'
import os,pathlib
pid=os.getppid()
while pid>1:
    try:
        root=pathlib.Path('/proc')/str(pid)
        for entry in (root/'environ').read_bytes().split(b'\0'):
            if entry.startswith(b'SSH_CONNECTION='):
                print(entry.split(b'=',1)[1].decode('ascii'))
                raise SystemExit(0)
        pid=int((root/'stat').read_text().rsplit(')',1)[1].split()[1])
    except (OSError,ValueError):
        break
PY
}

# UFW skips an insertion when an identical ALLOW already exists behind a DENY.
# Refuse activation when the requested source still encounters a blocking rule.
verify_ssh_firewall_rules() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import gettext,ipaddress,shutil,sys
from ufw.backend_iptables import UFWBackendIptables
gettext.install('ufw')
sys.argv[0]=shutil.which('ufw')
backend=UFWBackendIptables(False)
source,port=sys.argv[1],int(sys.argv[2])
networks=[source] if source else ['0.0.0.0/0']+(['::/0'] if backend.use_ipv6() else [])
def includes_port(ports):
    if ports=='any':return True
    for item in ports.split(','):
        ends=item.split(':');low=int(ends[0]);high=int(ends[-1])
        if low<=port<=high:return True
    return False
for value in networks:
    wanted=ipaddress.ip_network(value,strict=False)
    for rule in backend.get_rules():
        network=ipaddress.ip_network(rule.src,strict=False)
        if rule.forward or rule.direction!='in' or rule.protocol not in ('any','tcp'):
            continue
        if wanted.version!=network.version or not wanted.overlaps(network) or not includes_port(rule.dport):
            continue
        if rule.action!='allow':
            raise SystemExit('Existing UFW rule blocks requested SSH access; firewall activation refused')
        if wanted.subnet_of(network) and ipaddress.ip_network(rule.dst).prefixlen==0 and rule.sport=='any' and not rule.interface_in:
            break
    else:
        raise SystemExit('Cannot verify requested SSH access; firewall activation refused')
PY
}

# Add access before enabling UFW. Never reset policy or remove existing rules.
configure_install_firewall() {
    local source="${1-}" peer peer_port status connection
    validate_ssh_source "$source" || { echo 'Invalid SSH source address' >&2; return 1; }
    connection="${SSH_CONNECTION:-$(current_ssh_connection)}" || return 1
    if [[ -n "$source" ]]; then
        ufw insert 1 allow from "$source" to any port 22 proto tcp || return 1
    else
        ufw insert 1 allow 22/tcp || return 1
    fi
    if [[ -n "$connection" ]]; then
        read -r peer _ _ peer_port <<< "$connection"
        validate_ssh_source "$peer" || return 1
        [[ "$peer_port" =~ ^[0-9]+$ ]] || return 1
        # Retain the active management path even when a different source is selected.
        ufw insert 1 allow from "$peer" to any port "$peer_port" proto tcp || return 1
        verify_ssh_firewall_rules "$peer" "$peer_port" || return 1
    fi
    verify_ssh_firewall_rules "$source" 22 || return 1
    status=$(LC_ALL=C ufw status) || return 1
    if ! grep -q '^Status: active$' <<< "$status"; then
        ufw --force enable || return 1
    fi
    LC_ALL=C ufw status | grep -q '^Status: active$'
}

validate_fail2ban_allowlist() {
    python3 - "$1" <<'PY'
import ipaddress,sys
try:
    for value in sys.argv[1].split():
        if "%" in value:
            raise ValueError("Scoped IPv6 is unsupported")
        ipaddress.ip_network(value, strict=False)
except ValueError:
    raise SystemExit('Enter numeric IPv4/IPv6 addresses or CIDRs separated by spaces.')
PY
}

prompt_fail2ban_allowlist() {
    if [[ ${FT_FAIL2BAN_ALLOWLIST+x} ]]; then
        FAIL2BAN_ALLOWLIST="$FT_FAIL2BAN_ALLOWLIST"
        validate_fail2ban_allowlist "$FAIL2BAN_ALLOWLIST" || return 1
    else
        while true; do
            read -r -p 'Fail2ban trusted IPs/CIDRs for SSH and proxy (empty = preserve existing): ' FAIL2BAN_ALLOWLIST || return 1
            validate_fail2ban_allowlist "$FAIL2BAN_ALLOWLIST" && break
        done
    fi
    export FAIL2BAN_ALLOWLIST
}

# Extend effective per-jail exclusions without modifying operator source files.
configure_fail2ban_allowlist() {
    validate_fail2ban_allowlist "$1" || return 1
    [[ -n "${1//[[:space:]]/}" ]] || return 0
    /usr/bin/python3 - "${FT_FAIL2BAN_DIR:-/etc/fail2ban}" "$1" <<'PY'
import os,pathlib,sys,tempfile
from fail2ban.client.configparserinc import SafeConfigParserWithIncludes
base=pathlib.Path(sys.argv[1])
config=SafeConfigParserWithIncludes()
config.read([str(p) for p in [base/'jail.conf',*sorted((base/'jail.d').glob('*.conf')),
                            base/'jail.local',*sorted((base/'jail.d').glob('*.local'))]])
target=base/'jail.d/zz-familytraffic-allowlist.local'
if target.is_symlink():
    raise SystemExit('Refusing a symbolic link for the managed allowlist')
if target.exists():
    import configparser
    owned=configparser.ConfigParser(interpolation=None)
    owned.read(target)
    if owned.defaults() or any(section not in ('sshd','familytraffic-proxy-auth') or
                               set(owned[section]) != {'ignoreip'} for section in owned.sections()):
        raise SystemExit('Existing allowlist file contains other settings; operator review required')
text='# Managed by FamilyTraffic installer. Existing exclusions are preserved.\n'
for jail in ('sshd','familytraffic-proxy-auth'):
    existing=config.get(jail,'ignoreip',fallback='').replace(',',' ').split()
    if jail=='familytraffic-proxy-auth':
        existing+=['127.0.0.0/8','::1']
    values=list(dict.fromkeys(existing+sys.argv[2].split()))
    text+='\n['+jail+']\nignoreip = '+' '.join(values)+'\n'
old=target.read_bytes() if target.exists() else None
fd,name=tempfile.mkstemp(dir=target.parent)
try:
    with os.fdopen(fd,'w') as out:
        out.write(text)
    os.chmod(name,0o644)
    os.replace(name,target)
    effective=SafeConfigParserWithIncludes()
    effective.read([str(p) for p in [base/'jail.conf',*sorted((base/'jail.d').glob('*.conf')),
                                   base/'jail.local',*sorted((base/'jail.d').glob('*.local'))]])
    for jail in ('sshd','familytraffic-proxy-auth'):
        if not set(sys.argv[2].split()) <= set(effective.get(jail,'ignoreip').replace(',',' ').split()):
            raise ValueError('A later operator override cancels requested exclusions')
except Exception:
    if old is None:
        target.unlink(missing_ok=True)
    else:
        target.write_bytes(old)
    raise
finally:
    if os.path.exists(name):os.unlink(name)
PY
}
