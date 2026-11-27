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
        validate_ssh_source "$SSH_ALLOW_FROM" || { echo 'Invalid trusted firewall source' >&2; return 1; }
    else
        while true; do
            read -r -p 'Trusted IP or CIDR for all inbound host ports and protocols (empty = allow TCP 22 from any address): ' SSH_ALLOW_FROM || return 1
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

# Verify the resulting order before enabling an inactive firewall.
verify_ssh_firewall_rules() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import gettext,ipaddress,shutil,sys
from ufw.backend_iptables import UFWBackendIptables
gettext.install('ufw')
sys.argv[0]=shutil.which('ufw')
backend=UFWBackendIptables(False)
source,port=sys.argv[1:]
networks=[source] if source else ['0.0.0.0/0']+(['::/0'] if backend.use_ipv6() else [])
def includes_port(ports):
    if ports=='any':return True
    for item in ports.split(','):
        ends=item.split(':');low=int(ends[0]);high=int(ends[-1])
        if low<=int(port)<=high:return True
    return False
for value in networks:
    wanted=ipaddress.ip_network(value,strict=False)
    for rule in backend.get_rules():
        network=ipaddress.ip_network(rule.src,strict=False)
        if rule.forward or rule.direction!='in':
            continue
        if wanted.version!=network.version or not wanted.overlaps(network):
            continue
        if port!='any' and (rule.protocol not in ('any','tcp') or not includes_port(rule.dport)):
            continue
        if rule.action!='allow':
            raise SystemExit('Existing UFW rule blocks requested inbound access; firewall activation refused')
        if port=='any' and (rule.protocol!='any' or rule.dport!='any'):
            continue
        if wanted.subnet_of(network) and ipaddress.ip_network(rule.dst).prefixlen==0 and rule.sport=='any' and not rule.interface_in:
            break
    else:
        raise SystemExit('Cannot verify requested inbound access; firewall activation refused')
PY
}

# UFW's CLI skips duplicate rules, even when a DENY precedes the ALLOW.
# Build the complete order first and replace each live input chain atomically.
reconcile_ssh_firewall_rules() {
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import gettext,ipaddress,os,pathlib,shutil,subprocess,sys,tempfile
from ufw.backend_iptables import UFWBackendIptables
from ufw.common import UFWRule
from ufw.util import create_lock,release_lock
gettext.install('ufw')
sys.argv[0]=shutil.which('ufw')
lock=create_lock('/run/ufw.lock')
try:
    backend=UFWBackendIptables(False)
    source,peer,port=sys.argv[1:]
    requested=[(source,'any' if source else '22')]
    if peer:
        if not port.isdecimal() or not 1<=int(port)<=65535:
            raise ValueError('Invalid current SSH port')
        requested.insert(0,(peer,port))
    wanted=[]
    for address,number in requested:
        networks=[ipaddress.ip_network(address,strict=False)] if address else [ipaddress.ip_network('0.0.0.0/0')]
        if not address and backend.use_ipv6():
            networks.append(ipaddress.ip_network('::/0'))
        for network in networks:
            if network.version==6 and not backend.use_ipv6():
                raise ValueError('IPv6 source requires IPv6 support in UFW')
            rule=UFWRule('allow','any' if number=='any' else 'tcp',dport=number,src=str(network),dst='any')
            rule.set_v6(network.version==6)
            rule.normalize()
            if not any(rule.match(old)==0 for old in wanted):
                wanted.append(rule)
    active=backend.is_enabled()
    backups={}
    live={}
    candidates={}
    def write(path,data):
        info=path.stat()
        fd,name=tempfile.mkstemp(dir=path.parent,prefix='.familytraffic-ssh-')
        try:
            with os.fdopen(fd,'wb') as stream:
                os.fchmod(stream.fileno(),info.st_mode)
                os.fchown(stream.fileno(),info.st_uid,info.st_gid)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name,path)
        finally:
            if os.path.exists(name): os.unlink(name)
    def payload(text,v6):
        chain='ufw6-user-input' if v6 else 'ufw-user-input'
        lines=[line for line in text.splitlines() if line.startswith('-A '+chain+' ')]
        return '*filter\n-F '+chain+'\n'+'\n'.join(lines)+'\nCOMMIT\n'
    def restore(v6,text,test=False):
        exe=backend.ip6tables_restore if v6 else backend.iptables_restore
        subprocess.run([exe,'--noflush',*(['--test'] if test else [])],input=text,text=True,check=True,capture_output=True)
    try:
        for v6 in sorted({rule.v6 for rule in wanted}):
            path=pathlib.Path(backend.files['rules6' if v6 else 'rules'])
            backups[v6]=(path,path.read_bytes())
            text=backups[v6][1].decode()
            prefix='ufw6' if v6 else 'ufw'
            chain=prefix+'-user-input'
            blocks=[]
            permissions=[]
            for rule in wanted:
                if rule.v6!=v6: continue
                # Separate managed tuples avoid UFW's duplicate/action matching.
                marker=('FamilyTraffic trusted source' if rule.protocol=='any' else 'FamilyTraffic SSH management').encode().hex()
                block='\n### tuple ### allow '+rule.protocol+' '+rule.dport+' '+rule.dst+' any '+rule.src+' in comment='+marker+'\n'
                block+='-A '+chain+' '+rule.format_rule().replace('-p all ', '', 1)+'\n'
                text=text.replace(block,'')
                blocks.append(block)
                network=ipaddress.ip_network(rule.src,strict=False)
                ports=' -p tcp -m tcp --dport '+rule.dport if rule.protocol=='tcp' else ''
                permissions.append('-A '+chain+(' -s '+str(network) if network.prefixlen else '')+ports+' -j ACCEPT')
            lines=text.splitlines(keepends=True)
            position=next((i for i,line in enumerate(lines) if line.startswith(('### RULES ###','### tuple ###','-A ','-I ','COMMIT'))),None)
            if position is None:
                raise ValueError('Cannot locate UFW filter rules')
            updated=(''.join(lines[:position])+''.join(blocks)+''.join(lines[position:])).encode()
            if active:
                exe=backend.ip6tables if v6 else backend.iptables
                current=subprocess.run([exe,'-S',chain],check=True,capture_output=True,text=True).stdout
                live[v6]=payload(current,v6)
                remaining=[line for line in current.splitlines() if line.startswith('-A '+chain+' ') and line not in permissions]
                candidates[v6]=payload('\n'.join(permissions+remaining),v6)
            if updated!=backups[v6][1]:
                write(path,updated)
        if active:
            for v6 in candidates:
                restore(v6,candidates[v6],test=True)
            for v6 in candidates:
                if candidates[v6]!=live[v6]:
                    restore(v6,candidates[v6])
    except Exception:
        failures=[]
        for path,data in backups.values():
            try: write(path,data)
            except Exception as error: failures.append(str(error))
        for v6,text in live.items():
            try: restore(v6,text)
            except Exception as error: failures.append(str(error))
        if failures:
            print('UFW recovery failed: '+'; '.join(failures),file=sys.stderr)
        raise
except Exception as error:
    print('Cannot reconcile inbound firewall rules: '+str(error),file=sys.stderr)
    sys.exit(1)
finally:
    release_lock(lock)
PY
}

# Native activation rewrites user.rules while preparing logging. Retain raw rules.
enable_install_firewall() {
    /usr/bin/python3 - <<'PY'
import gettext,os,pathlib,shutil,sys,tempfile
from ufw.frontend import UFWFrontend
from ufw.util import create_lock,release_lock
gettext.install('ufw')
sys.argv[0]=shutil.which('ufw')
lock=create_lock('/run/ufw.lock')
try:
    frontend=UFWFrontend(False)
    saved={pathlib.Path(frontend.backend.files[key]):pathlib.Path(frontend.backend.files[key]).read_bytes() for key in ('rules','rules6')}
    try:
        frontend.set_enabled(True)
    finally:
        failures=[]
        for path,data in saved.items():
            name=None
            try:
                info=path.stat()
                fd,name=tempfile.mkstemp(dir=path.parent,prefix='.familytraffic-ssh-')
                with os.fdopen(fd,'wb') as stream:
                    os.fchmod(stream.fileno(),info.st_mode)
                    os.fchown(stream.fileno(),info.st_uid,info.st_gid)
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name,path)
            except Exception as error:
                failures.append(str(error))
            finally:
                if name and os.path.exists(name): os.unlink(name)
        if failures:
            raise RuntimeError('UFW activation file recovery failed: '+'; '.join(failures))
finally:
    release_lock(lock)
PY
}

# Add access before enabling UFW. Never reset policy or remove existing rules.
configure_install_firewall() {
    local source="${1-}" peer peer_port status connection selected_port=22
    validate_ssh_source "$source" || { echo 'Invalid trusted firewall source' >&2; return 1; }
    connection="${SSH_CONNECTION:-$(current_ssh_connection)}" || return 1
    if [[ -n "$connection" ]]; then
        read -r peer _ _ peer_port <<< "$connection"
        validate_ssh_source "$peer" || return 1
        [[ "$peer_port" =~ ^[0-9]+$ ]] || return 1
    fi
    reconcile_ssh_firewall_rules "$source" "${peer:-}" "${peer_port:-}" || return 1
    if [[ -n "$connection" ]]; then
        verify_ssh_firewall_rules "$peer" "$peer_port" || return 1
    fi
    [[ -z "$source" ]] || selected_port=any
    verify_ssh_firewall_rules "$source" "$selected_port" || return 1
    status=$(LC_ALL=C ufw status) || return 1
    if ! grep -q '^Status: active$' <<< "$status"; then
        enable_install_firewall || return 1
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
