#!/bin/bash
#
# UFW Whitelist Module for VLESS Reality VPN
# Version: 4.0
# Purpose: UFW-based IP whitelisting for proxy ports (1080, 8118)
#
# This module provides host-level firewall rules for proxy access control.
# Works in conjunction with Xray routing rules (application-level filtering).
#
# Architecture:
#   Defense-in-depth security layers:
#   1. UFW (host firewall) - this module
#   2. Xray routing - proxy_allowed_ips.json (existing v3.6)
#   3. Xray authentication - username/password
#   4. fail2ban - brute force protection
#

set -euo pipefail

# Shared helpers (validate_ip). Sourced explicitly rather than relying on the
# CLI having loaded common.sh first; the guard inside makes it idempotent.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Proxy ports
readonly SOCKS5_PORT=1080
readonly HTTP_PORT=8118

# UFW rule comment prefix
readonly UFW_COMMENT_PREFIX="VLESS proxy whitelist"

# ============================================================================
# Logging Functions
# ============================================================================

log_ufw_info() {
    echo -e "${CYAN}[UFW]${NC} $*"
}

log_ufw_success() {
    echo -e "${GREEN}[UFW]${NC} ✓ $*"
}

log_ufw_warning() {
    echo -e "${YELLOW}[UFW]${NC} ⚠ $*"
}

log_ufw_error() {
    echo -e "${RED}[UFW]${NC} ✗ $*" >&2
}

# ============================================================================
# IP Validation — validate_ip lives in lib/common.sh
# ============================================================================
# Shared with proxy_whitelist.sh. The copy that used to sit here capped every
# CIDR prefix at 32 and therefore rejected ordinary IPv6 networks such as
# 2001:db8::/64 — and because the CLI sources this module last, that copy won.
# ============================================================================

# ============================================================================
# UFW Status Check
# ============================================================================

#
# check_ufw_installed()
#
# Check if UFW is installed
#
# Returns:
#   0 - UFW installed
#   1 - UFW not installed
#
check_ufw_installed() {
    if command -v ufw &>/dev/null; then
        return 0
    else
        return 1
    fi
}

#
# check_ufw_active()
#
# Check if UFW is active
#
# Returns:
#   0 - UFW active
#   1 - UFW inactive
#
check_ufw_active() {
    if ufw status | grep -q "Status: active"; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# UFW Rule Management
# ============================================================================

#
# add_ufw_proxy_rule()
#
# Add UFW rule to allow IP access to proxy ports
#
# Arguments:
#   $1 - IP address or CIDR
#
# Returns:
#   0 - Success
#   1 - Failure
#
add_ufw_proxy_rule() {
    local ip="$1"

    log_ufw_info "Adding UFW rule for IP: $ip"

    # Validate IP
    if ! validate_ip "$ip"; then
        log_ufw_error "Invalid IP address or CIDR: $ip"
        return 1
    fi

    # Check UFW installed
    if ! check_ufw_installed; then
        log_ufw_error "UFW not installed. Install: sudo apt install ufw"
        return 1
    fi

    # Check UFW active
    if ! check_ufw_active; then
        log_ufw_warning "UFW is not active. Enable with: sudo ufw enable"
        return 1
    fi

    # Check if rule already exists
    if ufw status numbered | grep -q "# ${UFW_COMMENT_PREFIX}: ${ip}"; then
        log_ufw_warning "UFW rule already exists for $ip"
        return 0
    fi

    # Add rules for both SOCKS5 and HTTP ports
    local errors=0

    # SOCKS5 port (1080)
    if ! ufw allow from "$ip" to any port "$SOCKS5_PORT" proto tcp comment "${UFW_COMMENT_PREFIX}: ${ip} SOCKS5" &>/dev/null; then
        log_ufw_error "Failed to add UFW rule for SOCKS5 port ($SOCKS5_PORT)"
        ((errors++))
    fi

    # HTTP port (8118)
    if ! ufw allow from "$ip" to any port "$HTTP_PORT" proto tcp comment "${UFW_COMMENT_PREFIX}: ${ip} HTTP" &>/dev/null; then
        log_ufw_error "Failed to add UFW rule for HTTP port ($HTTP_PORT)"
        ((errors++))
    fi

    if [[ $errors -eq 0 ]]; then
        log_ufw_success "Added UFW rules for $ip (ports $SOCKS5_PORT, $HTTP_PORT)"
        return 0
    else
        log_ufw_error "Failed to add some UFW rules for $ip"
        return 1
    fi
}

#
# remove_ufw_proxy_rule()
#
# Remove UFW rule for specific IP
#
# Arguments:
#   $1 - IP address or CIDR
#
# Returns:
#   0 - Success
#   1 - Failure
#
remove_ufw_proxy_rule() {
    local ip="$1"

    log_ufw_info "Removing UFW rule for IP: $ip"

    # Validate IP
    if ! validate_ip "$ip"; then
        log_ufw_error "Invalid IP address or CIDR: $ip"
        return 1
    fi

    # Check UFW installed
    if ! check_ufw_installed; then
        log_ufw_error "UFW not installed"
        return 1
    fi

    # Get rule numbers for this IP (reverse order to delete from bottom)
    local rule_numbers=$(ufw status numbered | grep "# ${UFW_COMMENT_PREFIX}: ${ip}" | \
                        awk '{print $1}' | tr -d '[]' | sort -rn)

    if [[ -z "$rule_numbers" ]]; then
        log_ufw_warning "No UFW rules found for $ip"
        return 0
    fi

    # Delete rules
    local deleted=0
    for rule_num in $rule_numbers; do
        if echo "y" | ufw delete "$rule_num" &>/dev/null; then
            ((deleted++))
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        log_ufw_success "Removed $deleted UFW rule(s) for $ip"
        return 0
    else
        log_ufw_error "Failed to remove UFW rules for $ip"
        return 1
    fi
}

#
# show_ufw_proxy_ips()
#
# Display current UFW rules for proxy ports
#
# Arguments:
#   None
#
# Returns:
#   0 - Always
#
show_ufw_proxy_ips() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       UFW Proxy Whitelist (Host Firewall Rules)          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check UFW installed
    if ! check_ufw_installed; then
        log_ufw_error "UFW not installed"
        echo ""
        echo "Install UFW: sudo apt install ufw"
        echo ""
        return 0
    fi

    # Check UFW active
    if ! check_ufw_active; then
        log_ufw_warning "UFW is inactive"
        echo ""
        echo "Enable UFW: sudo ufw enable"
        echo ""
        return 0
    fi

    # Show UFW status
    echo -e "${CYAN}UFW Status:${NC} $(ufw status | grep "Status:" | awk '{print $2}')"
    echo ""

    # Get proxy-related rules
    local proxy_rules=$(ufw status numbered | grep "${UFW_COMMENT_PREFIX}")

    if [[ -z "$proxy_rules" ]]; then
        echo -e "${YELLOW}No UFW proxy whitelist rules configured${NC}"
        echo ""
        echo "Add IP: sudo familytraffic add-ufw-ip <ip>"
        echo "Example: sudo familytraffic add-ufw-ip 192.168.1.100"
        echo ""
    else
        echo -e "${CYAN}Proxy Whitelist Rules:${NC}"
        echo ""
        echo "$proxy_rules" | nl -w2 -s'. '
        echo ""

        # Extract unique IPs
        local unique_ips=$(echo "$proxy_rules" | \
                          grep -oP "${UFW_COMMENT_PREFIX}: \K[0-9./:]+" | \
                          sed 's/ SOCKS5$//' | sed 's/ HTTP$//' | \
                          sort -u)

        local ip_count=$(echo "$unique_ips" | wc -l)

        echo -e "${CYAN}Allowed IPs (${ip_count}):${NC}"
        echo "$unique_ips" | while read -r ip; do
            echo "  • $ip"
        done
        echo ""
    fi

    echo -e "${CYAN}Ports Protected:${NC}"
    echo "  • SOCKS5: $SOCKS5_PORT/tcp"
    echo "  • HTTP:   $HTTP_PORT/tcp"
    echo ""

    echo -e "${CYAN}Management Commands:${NC}"
    echo "  sudo familytraffic add-ufw-ip <ip>       # Add IP to whitelist"
    echo "  sudo familytraffic remove-ufw-ip <ip>    # Remove IP from whitelist"
    echo "  sudo familytraffic reset-ufw-ips         # Remove all rules"
    echo ""
}

#
# reset_ufw_proxy_ips()
#
# Remove ALL UFW proxy whitelist rules
#
# Arguments:
#   None
#
# Returns:
#   0 - Success
#   1 - Failure
#
reset_ufw_proxy_ips() {
    echo ""
    echo -e "${YELLOW}⚠ WARNING: This will remove ALL UFW proxy whitelist rules${NC}"
    echo ""

    # Check UFW installed
    if ! check_ufw_installed; then
        log_ufw_error "UFW not installed"
        return 1
    fi

    # Get all proxy rule numbers
    local rule_numbers=$(ufw status numbered | grep "${UFW_COMMENT_PREFIX}" | \
                        awk '{print $1}' | tr -d '[]' | sort -rn)

    if [[ -z "$rule_numbers" ]]; then
        log_ufw_warning "No UFW proxy rules to remove"
        return 0
    fi

    local rule_count=$(echo "$rule_numbers" | wc -l)
    echo "Found $rule_count proxy rule(s) to remove"
    echo ""

    read -p "Continue? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
        log_ufw_info "Reset cancelled"
        return 0
    fi

    # Delete all rules
    log_ufw_info "Removing UFW proxy rules..."
    local deleted=0
    for rule_num in $rule_numbers; do
        if echo "y" | ufw delete "$rule_num" &>/dev/null; then
            ((deleted++))
        fi
    done

    echo ""
    if [[ $deleted -eq $rule_count ]]; then
        log_ufw_success "Removed all $deleted UFW proxy rule(s)"
        return 0
    else
        log_ufw_error "Removed $deleted of $rule_count rules (some failed)"
        return 1
    fi
}

# ============================================================================
# Bulk Operations
# ============================================================================

#
# set_ufw_proxy_ips()
#
# Set UFW whitelist to specific IP list (replaces all existing rules)
#
# Arguments:
#   $1 - Comma-separated IP list (e.g., "192.168.1.1,10.0.0.0/8")
#
# Returns:
#   0 - Success
#   1 - Failure
#
set_ufw_proxy_ips() {
    local ip_list="$1"

    log_ufw_info "Setting UFW whitelist to: $ip_list"

    # Parse IP list
    IFS=',' read -ra ips <<< "$ip_list"

    # Validate all IPs first
    local invalid=0
    for ip in "${ips[@]}"; do
        ip=$(echo "$ip" | xargs)  # Trim whitespace
        if ! validate_ip "$ip"; then
            log_ufw_error "Invalid IP: $ip"
            ((invalid++))
        fi
    done

    if [[ $invalid -gt 0 ]]; then
        log_ufw_error "Found $invalid invalid IP(s), aborting"
        return 1
    fi

    # Remove existing rules
    log_ufw_info "Removing existing UFW proxy rules..."
    local rule_numbers=$(ufw status numbered | grep "${UFW_COMMENT_PREFIX}" | \
                        awk '{print $1}' | tr -d '[]' | sort -rn)

    for rule_num in $rule_numbers; do
        echo "y" | ufw delete "$rule_num" &>/dev/null || true
    done

    # Add new rules
    log_ufw_info "Adding new UFW rules..."
    local added=0
    for ip in "${ips[@]}"; do
        ip=$(echo "$ip" | xargs)
        if add_ufw_proxy_rule "$ip"; then
            ((added++))
        fi
    done

    echo ""
    log_ufw_success "UFW whitelist updated: $added IP(s) configured"
    return 0
}

# ============================================================================
# Module Export
# ============================================================================

# Functions exported for use by other modules:
#   - add_ufw_proxy_rule(ip)           # Add IP to UFW whitelist
#   - remove_ufw_proxy_rule(ip)        # Remove IP from whitelist
#   - show_ufw_proxy_ips()             # Display current rules
#   - reset_ufw_proxy_ips()            # Remove all rules
#   - set_ufw_proxy_ips(ip_list)       # Replace all rules
#   - validate_ip(ip)                  # IP validation
#   - check_ufw_installed()            # Check UFW presence
#   - check_ufw_active()               # Check UFW status

# This module is sourced by:
#   - scripts/vless (UFW commands)
#   - lib/orchestrator.sh (optional during installation)
