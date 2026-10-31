#!/bin/bash
################################################################################
# VLESS Reality VPN - Fail2ban Setup Module
#
# Description:
#   Installs and configures fail2ban to protect SOCKS5 and HTTP proxy ports
#   from brute-force authentication attacks.
#
# Requirements:
#   - Ubuntu 20.04+ or Debian 10+
#   - Root privileges
#   - Xray error logs at /opt/familytraffic/logs/xray/error.log
#
# Features:
#   - Auto-install fail2ban if missing
#   - Create custom filter for Xray authentication failures
#   - Configure jails for SOCKS5 (1080) and HTTP (8118)
#   - Ban after 5 failed attempts for 1 hour
#
# Version: 3.2
# Date: 2025-10-04
################################################################################

set -euo pipefail

# Color codes for output (only define if not already set to avoid readonly conflicts)
[[ -z "${RED:-}" ]] && RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && YELLOW='\033[0;33m'
[[ -z "${CYAN:-}" ]] && CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && NC='\033[0m'

# =============================================================================
# FUNCTION: check_fail2ban_installed
# =============================================================================
# Description: Check if fail2ban is installed
# Returns: 0 if installed, 1 if not installed
# =============================================================================
check_fail2ban_installed() {
    if command -v fail2ban-server &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# FUNCTION: install_fail2ban
# =============================================================================
# Description: Install fail2ban package
# Returns: 0 on success, 1 on failure
# =============================================================================
install_fail2ban() {
    echo -e "${CYAN}Installing fail2ban...${NC}"

    # Update package list
    if ! apt-get update -qq; then
        echo -e "${RED}Failed to update package list${NC}" >&2
        return 1
    fi

    # Install fail2ban
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban; then
        echo -e "${RED}Failed to install fail2ban${NC}" >&2
        return 1
    fi

    # Enable and start service
    systemctl enable fail2ban &>/dev/null || true
    systemctl start fail2ban || true

    echo -e "${GREEN}✓ Fail2ban installed${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_familytraffic_proxy_filter
# =============================================================================
# Description: Create custom fail2ban filter for Xray proxy authentication
# Returns: 0 on success, 1 on failure
# =============================================================================
create_familytraffic_proxy_filter() {
    echo -e "${CYAN}Creating fail2ban filter for VLESS proxy...${NC}"

    local filter_file="/etc/fail2ban/filter.d/familytraffic-proxy.conf"

    cat > "$filter_file" <<'EOF'
# Fail2ban filter for VLESS Reality Proxy (SOCKS5 + HTTP)
#
# Matches Xray authentication failure patterns in error logs
#
# Author: VLESS Reality VPN v3.2
# Date: 2025-10-04

[Definition]

# Match authentication failures in Xray logs
failregex = ^.* rejected .* from <HOST>.*$
            ^.* authentication failed .* from <HOST>.*$
            ^.* invalid credentials .* from <HOST>.*$
            ^.* proxy: failed to .* from <HOST>.*$

# Ignore successful connections
ignoreregex = ^.* accepted .* from .*$
              ^.* established .* from .*$
EOF

    if [[ ! -f "$filter_file" ]]; then
        echo -e "${RED}Failed to create filter file${NC}" >&2
        return 1
    fi

    chmod 644 "$filter_file"
    echo -e "${GREEN}✓ Filter created: $filter_file${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_familytraffic_proxy_jails
# =============================================================================
# Description: Create fail2ban jails for SOCKS5 and HTTP proxy
# Returns: 0 on success, 1 on failure
# =============================================================================
create_familytraffic_proxy_jails() {
    echo -e "${CYAN}Creating fail2ban jails for proxy ports...${NC}"

    local jail_file="/etc/fail2ban/jail.d/familytraffic-proxy.conf"

    cat > "$jail_file" <<'EOF'
# Fail2ban jails for VLESS Reality Proxy
#
# DISABLED BY DESIGN (enabled = false). These jails cannot ban real attackers in the
# current architecture and are kept only as documented scaffolding:
#   - nginx terminates TLS and forwards proxy traffic to xray over loopback WITHOUT the
#     PROXY protocol, so xray only ever sees 127.0.0.1 — a real ban would hit loopback and
#     break the nginx -> xray chain (hence ignoreip below as a safety belt).
#   - Proxy auth uses 128-bit random credentials → brute-force is infeasible.
#   - xray's HTTP inbound does not log auth failures at all; only SOCKS logs them, and to
#     access.log (not error.log), in the form: "from tcp:<HOST>:port rejected  proxy/socks: ...".
#
# To re-enable meaningfully: add `proxy_protocol on` to the nginx proxy_pass blocks +
# `sockopt.acceptProxyProtocol=true` to the xray inbounds, set logpath to access.log,
# fix the familytraffic-proxy failregex to the real format above, then set enabled = true.
#
# Author: VLESS Reality VPN v3.2
# Date: 2025-10-04

[familytraffic-socks5]
enabled  = false
port     = 1080
protocol = tcp
filter   = familytraffic-proxy
logpath  = /opt/familytraffic/logs/xray/access.log
ignoreip = 127.0.0.1/8 ::1
maxretry = 5
bantime  = 3600
findtime = 600
action   = iptables-multiport[name=familytraffic-socks5, port="1080", protocol=tcp]

[familytraffic-http]
enabled  = false
port     = 8118
protocol = tcp
filter   = familytraffic-proxy
logpath  = /opt/familytraffic/logs/xray/access.log
ignoreip = 127.0.0.1/8 ::1
maxretry = 5
bantime  = 3600
findtime = 600
action   = iptables-multiport[name=familytraffic-http, port="8118", protocol=tcp]
EOF

    # Append no-TLS jails if enabled (v5.35)
    if [[ "${PROXY_NOTLS_ENABLED:-false}" == "true" ]]; then
        cat >> "$jail_file" <<'EOF'

[familytraffic-socks5-notls]
enabled  = false
port     = 1081
protocol = tcp
filter   = familytraffic-proxy
logpath  = /opt/familytraffic/logs/xray/access.log
ignoreip = 127.0.0.1/8 ::1
maxretry = 5
bantime  = 3600
findtime = 600
action   = iptables-multiport[name=familytraffic-socks5-notls, port="1081", protocol=tcp]

[familytraffic-http-notls]
enabled  = false
port     = 8119
protocol = tcp
filter   = familytraffic-proxy
logpath  = /opt/familytraffic/logs/xray/access.log
ignoreip = 127.0.0.1/8 ::1
maxretry = 5
bantime  = 3600
findtime = 600
action   = iptables-multiport[name=familytraffic-http-notls, port="8119", protocol=tcp]
EOF
    fi

    if [[ ! -f "$jail_file" ]]; then
        echo -e "${RED}Failed to create jail file${NC}" >&2
        return 1
    fi

    chmod 644 "$jail_file"
    echo -e "${GREEN}✓ Jails created: $jail_file${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_xray_reality_filter (v5.32 DPI Hardening)
# =============================================================================
# Description: Create custom fail2ban filter for Xray Reality handshake failures
# Purpose: Protect against active probing attacks (GFW-style)
# Returns: 0 on success, 1 on failure
# =============================================================================
create_xray_reality_filter() {
    echo -e "${CYAN}Creating fail2ban filter for Reality handshakes...${NC}"

    local filter_file="/etc/fail2ban/filter.d/xray-reality.conf"

    cat > "$filter_file" <<'EOF'
# Fail2ban filter for VLESS Reality Protocol (v5.32 DPI Hardening)
#
# Matches Xray Reality handshake failure patterns in error logs
# Purpose: Detect and block active probing attacks
#
# Author: VLESS Reality VPN v5.32
# Date: 2025-10-30

[Definition]

# Match Reality handshake failures
failregex = ^.* rejected .* reality.*<HOST>.*$
            ^.* invalid.*handshake.* from <HOST>.*$
            ^.* invalid.*reality.* from <HOST>.*$
            ^.* authentication.*failed.* from <HOST>.*$
            ^.* connection.*rejected.* from <HOST>.*$
            ^.* tls.*handshake.*failed.* from <HOST>.*$

# Ignore successful connections
ignoreregex = ^.* accepted .* from .*$
              ^.* established .* from .*$
              ^.* connected .* from .*$
EOF

    if [[ ! -f "$filter_file" ]]; then
        echo -e "${RED}Failed to create filter file${NC}" >&2
        return 1
    fi

    chmod 644 "$filter_file"
    echo -e "${GREEN}✓ Reality filter created: $filter_file${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_xray_reality_jail (v5.32 DPI Hardening)
# =============================================================================
# Description: Create fail2ban jail for Reality handshake protection
# Purpose: Ban IPs after 10 failed handshake attempts (active probing detection)
# Returns: 0 on success, 1 on failure
# =============================================================================
create_xray_reality_jail() {
    echo -e "${CYAN}Creating fail2ban jail for Reality protection...${NC}"

    local jail_file="/etc/fail2ban/jail.d/xray-reality.conf"

    # v5.33: HAProxy removed — familytraffic (nginx+xray) uses host network, port 443 fixed
    # haproxy.cfg no longer exists; port is always 443 in single-container architecture
    local vless_port="443"

    # Also protect internal Xray port (8443) if different from external
    local xray_internal_port="8443"
    local port_list="$vless_port"
    if [[ "$vless_port" != "$xray_internal_port" ]]; then
        port_list="$vless_port,$xray_internal_port"
    fi

    echo -e "${CYAN}Detected VLESS external port: $vless_port${NC}"

    cat > "$jail_file" <<EOF
# Fail2ban jail for VLESS Reality Protocol (v5.32 DPI Hardening)
#
# DISABLED BY DESIGN (enabled = false). Reality answers active probes by transparently
# proxying to the real dest — it does not emit loggable "rejected reality" lines, so this
# filter never matches (0 bans observed in production). Anti-probing is handled inherently
# by Reality's fallback, not by fail2ban. Kept as scaffolding; set enabled = true only if a
# future xray version logs probe rejections that the failregex below can match.
#
# Author: VLESS Reality VPN v5.32
# Date: 2025-10-30

[xray-reality]
enabled  = false
port     = $port_list
protocol = tcp
filter   = xray-reality
logpath  = /opt/familytraffic/logs/xray/error.log
maxretry = 10
bantime  = 3600
findtime = 300
action   = iptables-multiport[name=xray-reality, port="$port_list", protocol=tcp]
EOF

    if [[ ! -f "$jail_file" ]]; then
        echo -e "${RED}Failed to create jail file${NC}" >&2
        return 1
    fi

    chmod 644 "$jail_file"
    echo -e "${GREEN}✓ Reality jail created: $jail_file (ports: $port_list)${NC}"
    return 0
}

# =============================================================================
# FUNCTION: reload_fail2ban
# =============================================================================
# Description: Reload fail2ban to apply new configuration
# Returns: 0 on success, 1 on failure
# =============================================================================
reload_fail2ban() {
    echo -e "${CYAN}Reloading fail2ban...${NC}"

    if ! systemctl reload fail2ban; then
        echo -e "${YELLOW}Reload failed, trying restart...${NC}"
        if ! systemctl restart fail2ban; then
            echo -e "${RED}Failed to restart fail2ban${NC}" >&2
            return 1
        fi
    fi

    # Wait for service to stabilize
    sleep 2

    echo -e "${GREEN}✓ Fail2ban reloaded${NC}"
    return 0
}

# =============================================================================
# FUNCTION: verify_fail2ban_jails
# =============================================================================
# Description: Verify fail2ban is running. Proxy/Reality jails are disabled by design
#              (see create_*_jail comments), so the active protection here is sshd.
# Returns: 0 if fail2ban is up, 1 otherwise
# =============================================================================
verify_fail2ban_jails() {
    echo -e "${CYAN}Verifying fail2ban...${NC}"

    if ! fail2ban-client ping &>/dev/null; then
        echo -e "${RED}✗ fail2ban not responding${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ fail2ban running${NC}"
    echo -e "${YELLOW}  Proxy/Reality jails are disabled by design (cosmetic in this architecture).${NC}"
    echo -e "${YELLOW}  Active protection: sshd jail. See lib/fail2ban_setup.sh comments to re-enable.${NC}"
    return 0
}

# =============================================================================
# FUNCTION: setup_fail2ban_for_proxy
# =============================================================================
# Description: Main entry point - complete fail2ban setup for VLESS proxy
# Returns: 0 on success, 1 on failure
# =============================================================================
setup_fail2ban_for_proxy() {
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy_security.sh"
    local notls ports
    notls=$(resolve_proxy_notls "${PROXY_NOTLS_ENABLED-}" "${VLESS_DIR:-/opt/familytraffic}/.env") || return 1
    ports=$(proxy_auth_ports "$notls") || return 1
    reconcile_proxy_firewall "$notls" || return 1
    if ! check_fail2ban_installed; then install_fail2ban || return 1; fi
    configure_proxy_auth_jail "$ports" || return 1
    fail2ban-client -t >/dev/null 2>&1 || return 1
    reload_fail2ban || return 1
    verify_proxy_auth_jail "$ports" || return 1
    echo 'Proxy authentication jail configuration and live monitoring verified.'

}

# Export functions for use in other modules
export -f check_fail2ban_installed
export -f install_fail2ban
export -f create_familytraffic_proxy_filter
export -f create_familytraffic_proxy_jails
export -f create_xray_reality_filter
export -f create_xray_reality_jail
export -f reload_fail2ban
export -f verify_fail2ban_jails
export -f setup_fail2ban_for_proxy

# Render only the managed authentication jail. Ports cannot include SSH or Reality.
_render_proxy_auth_jail() {
    local ports="$1" log="$2"
    cat <<JAIL
# Managed by FamilyTraffic proxy security. Do not edit this file.
[familytraffic-proxy-auth]
enabled = true
backend = polling
usedns = no
filter = familytraffic-proxy-auth
logpath = $log
port = $ports
protocol = tcp
ignoreip = 127.0.0.0/8 ::1
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=familytraffic-proxy-auth, port="$ports", protocol=tcp]
JAIL
}

_render_proxy_auth_filter() {
    cat <<'FILTER'
# Managed by FamilyTraffic proxy security. Do not edit this file.
[Definition]
datepattern = ^%%Y-%%m-%%dT%%H:%%M:%%SZ
ip4 = (?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])
ip6 = (?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?:(?::[0-9a-f]{1,4}){1,6})|:(?:(?::[0-9a-f]{1,4}){1,7}|:))
failregex = ^ FT_AUTH_FAILURE protocol=(?:http|socks) src=(?!127\.|::1$)(?=(?:%(ip4)s|%(ip6)s)$)<ADDR>$
ignoreregex =
FILTER
}

_render_proxy_auth_rotation() {
    cat <<ROTATION
# Managed by FamilyTraffic proxy security. Do not edit this file.
${FT_PROXY_AUTH_LOG:-/opt/familytraffic/logs/xray/auth.log} {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    create 0600 root root
    su root root
}
ROTATION
}

_proxy_auth_port_set() {
    [[ "$1" == 1080,8118 || "$1" == 1080,1081,8118,8119 ]]
}

# Validate ownership before touching any jail, filter, or legacy configuration.
_configure_proxy_auth_jail() {
    local ports="$1" base="${FT_FAIL2BAN_DIR:-/etc/fail2ban}" log="${FT_PROXY_AUTH_LOG:-/opt/familytraffic/logs/xray/auth.log}"
    local rotation="${FT_LOGROTATE_DIR:-/etc/logrotate.d}/familytraffic-proxy-auth" file digest candidate
    _proxy_auth_port_set "$ports" || return 1
    if [[ ! -f "$log" || -L "$log" || ! -w "$log" || "$(stat -c %a "$log")" != 600 ]]; then
        echo 'Proxy authentication journal must exist, be writable, and have mode 0600' >&2
        return 1
    fi
    local jail="$base/jail.d/familytraffic-proxy-auth.conf" filter="$base/filter.d/familytraffic-proxy-auth.conf"
    local -a legacy=()
    for file in "$base/jail.conf" "$base/jail.local" "$base"/jail.d/*.conf "$base"/jail.d/*.local; do
        [[ -f "$file" ]] || continue
        [[ ! -L "$file" ]] || { echo "Refusing symlinked jail: $file" >&2; return 1; }
        if [[ "$file" == "$jail" ]]; then
            if ! cmp -s "$file" <(_render_proxy_auth_jail 1080,8118 "$log") &&
               ! cmp -s "$file" <(_render_proxy_auth_jail 1080,1081,8118,8119 "$log"); then
                echo "Customized managed jail requires review: $file" >&2; return 1
            fi
        elif grep -Eq '^\[(vless-http|vless-socks5|familytraffic-(proxy-auth|socks5|http)(-notls)?)\]' "$file"; then
            digest=$(sha256sum "$file"); digest="${digest%% *}"
            case "$digest" in
                c0d29d92e1a9fba923d020dfc75d406c92443809e743c900d233943cfb8e968f|909749e197e8ad03e0fa98ed04aafa5cac0596017bb013bfc3a41c29e76abc67) legacy+=("$file") ;;
                *) echo "Unrecognized legacy proxy jail requires review: $file" >&2; return 1 ;;
            esac
        fi
    done
    for candidate in "$filter" "$rotation"; do
        [[ ! -L "$candidate" ]] || return 1
        if [[ -e "$candidate" ]]; then
            if [[ "$candidate" == "$filter" ]]; then
                cmp -s "$candidate" <(_render_proxy_auth_filter) || { echo "Customized filter requires review: $candidate" >&2; return 1; }
            else
                cmp -s "$candidate" <(_render_proxy_auth_rotation) || { echo "Customized rotation requires review: $candidate" >&2; return 1; }
            fi
        fi
    done
    [[ "${2:-apply}" != check ]] || return 0
    mkdir -p "$base/jail.d" "$base/filter.d" "$(dirname "$rotation")" || return 1
    for file in "${legacy[@]}"; do
        [[ ! -e "$file.disabled" ]] || { echo "Legacy backup collision: $file.disabled" >&2; return 1; }
        cp -p --backup=numbered "$file" "$file.ft-security-backup" || return 1
        mv "$file" "$file.disabled" || return 1
    done
    _render_proxy_auth_filter > "$filter" || return 1
    _render_proxy_auth_jail "$ports" "$log" > "$jail" || return 1
    _render_proxy_auth_rotation > "$rotation" || return 1
    chmod 644 "$filter" "$jail" "$rotation" || return 1
}

# Verify live file monitoring and the actual thresholds and action port set.
verify_proxy_auth_jail() {
    local ports="$1" jail=familytraffic-proxy-auth log="${FT_PROXY_AUTH_LOG:-/opt/familytraffic/logs/xray/auth.log}"
    local effective status_text dump value
    _proxy_auth_port_set "$ports" || return 1
    fail2ban-client -t >/dev/null 2>&1 || return 1
    status_text=$(fail2ban-client status "$jail") || return 1
    [[ "$status_text" == *'File list:'* && "$status_text" == *"$log"* ]] || return 1
    dump=$(fail2ban-client -d 2>/dev/null) || return 1
    [[ "$dump" == *"['add', '$jail', 'polling']"* ]] || return 1
    for value in maxretry:5 findtime:600 bantime:3600 usedns:no; do
        effective=$(fail2ban-client get "$jail" "${value%%:*}") || return 1
        [[ "$effective" == "${value#*:}" ]] || return 1
    done
    effective=$(fail2ban-client get "$jail" logpath) || return 1
    [[ "$effective" == *"$log"* ]] || return 1
    effective=$(fail2ban-client get "$jail" action iptables-multiport port) || return 1
    [[ "$effective" == "$ports" ]] || return 1
    effective=$(fail2ban-client get "$jail" action iptables-multiport protocol) || return 1
    [[ "$effective" == tcp ]] || return 1
    effective=$(fail2ban-client get "$jail" ignoreip) || return 1
    effective=$(printf '%s\n' "$effective" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?|[a-fA-F0-9]*:[a-fA-F0-9:]+(/[0-9]+)?' | sort) || return 1
    [[ "$effective" == $'127.0.0.0/8\n::1' ]] || return 1
    effective=$(fail2ban-client get "$jail" failregex) || return 1
    [[ "$effective" == *'FT_AUTH_FAILURE protocol=(?:http|socks)'* ]] || return 1
    [[ "$(printf '%s\n' "$effective" | grep -Ec '\[[0-9]+\]:')" == 1 ]] || return 1
}

validate_proxy_jail_ownership() {
    _configure_proxy_auth_jail "$1" check
}

configure_proxy_auth_jail() {
    _configure_proxy_auth_jail "$1" apply
}
