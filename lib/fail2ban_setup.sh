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
    echo ""
    echo "═════════════════════════════════════════════════════"
    echo "  FAIL2BAN SETUP (v3.3 - Proxy Protection)"
    echo "═════════════════════════════════════════════════════"
    echo ""

    # Check if fail2ban is installed
    if ! check_fail2ban_installed; then
        echo -e "${YELLOW}Fail2ban not found, installing...${NC}"
        if ! install_fail2ban; then
            echo -e "${RED}Failed to install fail2ban${NC}" >&2
            return 1
        fi
    else
        echo -e "${GREEN}✓ Fail2ban already installed${NC}"
    fi

    # Create filter
    if ! create_familytraffic_proxy_filter; then
        return 1
    fi

    # Create jails
    if ! create_familytraffic_proxy_jails; then
        return 1
    fi

    # Create Reality handshake filter (v5.32 DPI Hardening)
    if ! create_xray_reality_filter; then
        return 1
    fi

    # Create Reality handshake jail (v5.32 DPI Hardening)
    if ! create_xray_reality_jail; then
        return 1
    fi

    # Reload fail2ban
    if ! reload_fail2ban; then
        return 1
    fi

    # Verify jails
    if ! verify_fail2ban_jails; then
        echo -e "${YELLOW}Warning: Jails verification failed${NC}"
        echo -e "${YELLOW}Check fail2ban logs: journalctl -u fail2ban -n 50${NC}"
    fi

    echo ""
    echo -e "${GREEN}✓ Fail2ban setup complete${NC}"
    echo ""
    echo "Configuration:"
    echo "  - Proxy jails (SOCKS5/HTTP, TLS + no-TLS): DISABLED by design"
    echo "  - Reality jail (443/8443): DISABLED by design"
    echo "  - Filter/jail files installed as documented scaffolding (enabled = false)"
    echo ""
    echo "Why disabled: nginx terminates TLS without PROXY protocol → xray sees only 127.0.0.1;"
    echo "proxy creds are 128-bit (brute-force infeasible); HTTP/Reality do not log catchable"
    echo "auth failures. Active brute-force protection is the sshd jail. See lib/fail2ban_setup.sh"
    echo "header comments for how to re-enable (requires proxy_protocol plumbing)."
    echo "═════════════════════════════════════════════════════"
    echo ""

    return 0
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
