#!/bin/bash
# ============================================================================
# VLESS Reality Deployment System
# Module: Post-Installation Verification
# Version: 1.0.0
# Task: TASK-1.8
# ============================================================================
#
# Purpose:
#   Verify that the installation completed successfully and all components
#   are functioning correctly. This module performs comprehensive checks
#   across all installation layers.
#
# Functions:
#   1. verify_installation()       - Main verification orchestrator
#   2. verify_directory_structure() - Check /opt/familytraffic filesystem
#   3. verify_file_permissions()   - Validate security permissions
#   4. verify_network_mode()     - Check Docker bridge network
#   5. verify_containers()         - Health check containers
#   6. verify_xray_config()        - Validate Xray configuration
#   7. verify_ufw_rules()          - Check firewall rules
#   8. verify_container_internet() - Test internet connectivity
#   9. verify_port_listening()     - Check VLESS port
#   10. display_verification_summary() - Show results
#
# Usage:
#   source lib/verification.sh
#   verify_installation
#
# Exit Codes:
#   0 = All verifications passed
#   1 = One or more verifications failed
#
# Dependencies:
#   - Docker & Docker Compose
#   - jq
#   - /opt/familytraffic installation
#
# Author: Claude Code Agent
# Date: 2025-10-02
# ============================================================================

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

VLESS_HOME="/opt/familytraffic"
# INSTALL_ROOT and XRAY_IMAGE are set as readonly in orchestrator.sh (loaded before verification.sh)
# Only set them if not already defined (standalone execution mode)
if [[ -z "${INSTALL_ROOT:-}" ]]; then
    INSTALL_ROOT="/opt/familytraffic"
fi
if [[ -z "${XRAY_IMAGE:-}" ]]; then
    XRAY_IMAGE="teddysun/xray:24.11.30"
fi
VERIFICATION_PASSED=true
VERIFICATION_ERRORS=()

# Colors for output
# Only define if not already set (to avoid conflicts when sourced after install.sh)
[[ -z "${RED:-}" ]] && RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && BLUE='\033[0;34m'
[[ -z "${NC:-}" ]] && NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

# Logging comes from lib/logger.sh — see the note there on why the output shape
# differs between a terminal and a captured stream.
# shellcheck source=lib/logger.sh
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

# ============================================================================
# Main Verification Function
# ============================================================================

verify_installation() {
    echo ""
    echo "======================================================================"
    echo "  VLESS Reality - Post-Installation Verification"
    echo "======================================================================"
    echo ""

    log_info "Starting comprehensive verification checks..."
    echo ""

    # Run all verification checks
    verify_directory_structure
    verify_file_permissions
    verify_containers
    verify_network_mode
    verify_xray_config
    test_xray_config
    validate_mandatory_tls
    verify_ufw_rules
    verify_container_internet
    verify_port_listening

    # Display summary
    display_verification_summary

    # Return exit code
    if [[ "$VERIFICATION_PASSED" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Check 1: Directory Structure
# ============================================================================

verify_directory_structure() {
    log_info "Verification 1/8: Checking directory structure..."

    local required_dirs=(
        "$VLESS_HOME"
        "$VLESS_HOME/config"
        "$VLESS_HOME/data"
        "$VLESS_HOME/data/clients"
        "$VLESS_HOME/keys"
        "$VLESS_HOME/logs"
        "$VLESS_HOME/fake-site"
        "$VLESS_HOME/scripts"
        "$VLESS_HOME/docs"
        "$VLESS_HOME/tests"
        "$VLESS_HOME/tests/unit"
        "$VLESS_HOME/tests/integration"
        "$VLESS_HOME/backup"
    )

    local missing_dirs=()

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done

    if [[ ${#missing_dirs[@]} -eq 0 ]]; then
        log_success "All required directories exist (${#required_dirs[@]} directories)"
    else
        log_error "Missing directories (${#missing_dirs[@]}):"
        for dir in "${missing_dirs[@]}"; do
            echo "    - $dir"
        done
    fi

    # Check required files
    local required_files=(
        "$VLESS_HOME/docker-compose.yml"
        "$VLESS_HOME/.env"
        "$VLESS_HOME/config/xray_config.json"
        "$VLESS_HOME/config/nginx/nginx.conf"
        "$VLESS_HOME/data/users.json"
        "$VLESS_HOME/keys/private.key"
        "$VLESS_HOME/keys/public.key"
    )

    local missing_files=()

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done

    if [[ ${#missing_files[@]} -eq 0 ]]; then
        log_success "All required files exist (${#required_files[@]} files)"
    else
        log_error "Missing files (${#missing_files[@]}):"
        for file in "${missing_files[@]}"; do
            echo "    - $file"
        done
    fi

    echo ""
}

# ============================================================================
# Check 2: File Permissions
# ============================================================================

verify_file_permissions() {
    log_info "Verification 2/8: Checking file permissions..."

    local permission_errors=0

    # Check sensitive directories (should be 700)
    local sensitive_dirs=(
        "$VLESS_HOME/keys"
        "$VLESS_HOME/data"
        "$VLESS_HOME/data/clients"
    )

    for dir in "${sensitive_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local perms=$(stat -c '%a' "$dir" 2>/dev/null || echo "000")
            if [[ "$perms" != "700" ]]; then
                log_error "Directory $dir has incorrect permissions: $perms (expected 700)"
                ((permission_errors++))
            fi
        fi
    done

    # Check sensitive files (should be 600)
    local sensitive_files=(
        "$VLESS_HOME/.env"
        "$VLESS_HOME/keys/private.key"
        "$VLESS_HOME/keys/public.key"
        "$VLESS_HOME/data/users.json"
    )

    for file in "${sensitive_files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms=$(stat -c '%a' "$file" 2>/dev/null || echo "000")
            if [[ "$perms" != "600" ]]; then
                log_error "File $file has incorrect permissions: $perms (expected 600)"
                ((permission_errors++))
            fi
        fi
    done

    # Check ownership (all files should be owned by root)
    local all_paths=(
        "$VLESS_HOME"
        "$VLESS_HOME/config"
        "$VLESS_HOME/data"
        "$VLESS_HOME/keys"
    )

    for path in "${all_paths[@]}"; do
        if [[ -e "$path" ]]; then
            local owner=$(stat -c '%U' "$path" 2>/dev/null || echo "unknown")
            if [[ "$owner" != "root" ]]; then
                log_error "Path $path has incorrect owner: $owner (expected root)"
                ((permission_errors++))
            fi
        fi
    done

    if [[ $permission_errors -eq 0 ]]; then
        log_success "All file permissions and ownership are correct"
    else
        log_error "Found $permission_errors permission/ownership issues"
    fi

    echo ""
}

# ============================================================================
# Check 3: Docker Network
# ============================================================================

verify_network_mode() {
    log_info "Verification 4/8: Checking Docker network mode..."

    # v5.33: single container uses network_mode: host (no bridge network needed)
    local net_mode
    net_mode=$(docker inspect familytraffic -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "")

    if [[ "$net_mode" == "host" ]]; then
        log_success "Container 'familytraffic' uses network_mode: host (v5.33 architecture)"
    elif [[ -z "$net_mode" ]]; then
        log_error "Container 'familytraffic' not found or not running"
    else
        log_error "Container 'familytraffic' unexpected network mode: $net_mode (expected: host)"
    fi

    echo ""
}

# ============================================================================
# Check 4: Container Health
# ============================================================================

verify_containers() {
    log_info "Verification 3/8: Checking container health..."

    # Check xray container using docker inspect (more reliable)
    local xray_status=$(docker inspect familytraffic -f '{{.State.Status}}' 2>/dev/null || echo "not-found")
    if [[ "$xray_status" == "running" ]]; then
        log_success "Container 'familytraffic' is running"

        # Check uptime
        local started_at=$(docker inspect familytraffic -f '{{.State.StartedAt}}' 2>/dev/null || echo "")
        if [[ -n "$started_at" ]]; then
            log_info "  Started at: $started_at"
        fi

        # Check for critical errors in logs
        local xray_logs=$(docker logs familytraffic 2>&1 | tail -20)
        if echo "$xray_logs" | grep -qE "(CRITICAL|FATAL|panic)"; then
            log_warning "Container 'familytraffic' has critical messages in logs"
        fi
    elif [[ "$xray_status" == "not-found" ]]; then
        log_error "Container 'familytraffic' not found"
    else
        log_error "Container 'familytraffic' exists but status is: $xray_status"
    fi

    # Check nginx container using docker inspect (more reliable)
    local nginx_status=$(docker inspect familytraffic -f '{{.State.Status}}' 2>/dev/null || echo "not-found")
    if [[ "$nginx_status" == "running" ]]; then
        log_success "Container 'familytraffic' is running"

        # Check uptime
        local started_at=$(docker inspect familytraffic -f '{{.State.StartedAt}}' 2>/dev/null || echo "")
        if [[ -n "$started_at" ]]; then
            log_info "  Started at: $started_at"
        fi

        # Check healthcheck status (added in v4.1.1)
        local nginx_health=$(docker inspect familytraffic -f '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
        if [[ "$nginx_health" == "healthy" ]]; then
            log_success "Container 'familytraffic' health: healthy"
        elif [[ "$nginx_health" == "starting" ]]; then
            log_info "  Container 'familytraffic' health: starting"
        elif [[ "$nginx_health" == "unhealthy" ]]; then
            log_error "Container 'familytraffic' health: unhealthy"
        fi

        # Check Nginx logs for critical errors only (ignore informational warnings)
        local nginx_logs=$(docker logs familytraffic 2>&1 | tail -20)
        if echo "$nginx_logs" | grep -q "nginx: \[emerg\]"; then
            log_error "Container 'familytraffic' has critical errors in logs"
        elif echo "$nginx_logs" | grep -qE "(can not modify|read-only file system)"; then
            log_info "  Nginx running in read-only mode (expected for security)"
        fi
    elif [[ "$nginx_status" == "not-found" ]]; then
        log_error "Container 'familytraffic' not found"
    else
        log_error "Container 'familytraffic' exists but status is: $nginx_status"
    fi

    # Check restart policy
    local xray_restart=$(docker inspect familytraffic -f '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "")
    if [[ "$xray_restart" == "unless-stopped" ]]; then
        log_success "Container 'familytraffic' restart policy: unless-stopped"
    else
        log_warning "Container 'familytraffic' restart policy: $xray_restart (expected unless-stopped)"
    fi

    # v5.33: HAProxy removed — public proxy handled by nginx inside familytraffic container
    # No separate HAProxy container check needed

    echo ""
}

# ============================================================================
# Check 5: Xray Configuration Validation
# ============================================================================

verify_xray_config() {
    log_info "Verification 5/8: Validating Xray configuration..."

    local config_file="$VLESS_HOME/config/xray_config.json"

    # Check if config exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Xray configuration file not found: $config_file"
        echo ""
        return 1
    fi

    # Validate JSON syntax
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "Invalid JSON syntax in xray_config.json"
        echo ""
        return 1
    fi

    log_success "Xray configuration JSON syntax is valid"

    # Validate with xray -test
    if docker exec familytraffic xray -test -config=/etc/xray/config.json &>/dev/null; then
        log_success "Xray configuration validation passed (xray -test)"
    else
        log_error "Xray configuration validation failed (xray -test)"
        # Show detailed error
        local error_output=$(docker exec familytraffic xray -test -config=/etc/xray/config.json 2>&1 || true)
        echo "    Error details:"
        echo "$error_output" | sed 's/^/    /'
    fi

    # Verify critical configuration elements
    local protocol=$(jq -r '.inbounds[0].protocol' "$config_file" 2>/dev/null || echo "")
    if [[ "$protocol" == "vless" ]]; then
        log_success "Inbound protocol: vless"
    else
        log_error "Inbound protocol is '$protocol' (expected 'vless')"
    fi

    local security=$(jq -r '.inbounds[0].streamSettings.security' "$config_file" 2>/dev/null || echo "")
    if [[ "$security" == "reality" ]]; then
        log_success "Stream security: reality"
    else
        log_error "Stream security is '$security' (expected 'reality')"
    fi

    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$config_file" 2>/dev/null || echo "")
    if [[ -n "$private_key" && "$private_key" != "null" ]]; then
        log_success "Reality private key is configured"
    else
        log_error "Reality private key is missing or null"
    fi

    local dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$config_file" 2>/dev/null || echo "")
    if [[ -n "$dest" && "$dest" != "null" ]]; then
        log_success "Reality destination: $dest"
    else
        log_error "Reality destination is missing or null"
    fi

    echo ""
}

# ============================================================================
# Check 6: UFW Firewall Rules
# ============================================================================

verify_ufw_rules() {
    log_info "Verification 6/10: Checking UFW firewall rules..."

    # Check if UFW is installed and active
    if ! command -v ufw &>/dev/null; then
        log_warning "UFW is not installed"
        echo ""
        return 0
    fi

    local ufw_status=$(ufw status 2>/dev/null | head -n1 || echo "")
    if [[ "$ufw_status" =~ "Status: active" ]]; then
        log_success "UFW is active"
    else
        log_warning "UFW is not active"
        echo ""
        return 0
    fi

    # Check VLESS port rule (v5.33: Nginx stream on 443, Xray on 8443 internal)
    local vless_port=$(jq -r '.inbounds[0].port' "$VLESS_HOME/config/xray_config.json" 2>/dev/null || echo "8443")

    # In v5.33: Port 443 must be in UFW (Nginx stream frontend), port 8443 is internal
    if [[ "$vless_port" == "8443" ]]; then
        # v5.33 architecture: Check port 443 (Nginx stream) instead
        if ufw status numbered | grep -q "443/tcp.*ALLOW"; then
            log_success "UFW allows port 443/tcp (Nginx stream frontend)"
            log_info "  Port 8443 is internal (Nginx → Xray, not in UFW) - expected for v5.33"
        else
            log_error "UFW does not allow port 443/tcp (required for Nginx stream)"
        fi
    else
        # Legacy architecture or custom port
        if ufw status numbered | grep -q "${vless_port}/tcp.*ALLOW"; then
            log_success "UFW allows port $vless_port/tcp"
        else
            log_error "UFW does not allow port $vless_port/tcp"
        fi
    fi

    # Check Docker forwarding rules in after.rules
    # v5.33: marker changed to "FAMILYTRAFFIC DOCKER FORWARDING RULES"
    # network_mode:host — no MASQUERADE needed, DOCKER-USER chain kept for compatibility
    if [[ -f /etc/ufw/after.rules ]]; then
        if grep -q "BEGIN FAMILYTRAFFIC DOCKER FORWARDING RULES" /etc/ufw/after.rules; then
            log_success "Docker forwarding rules found in /etc/ufw/after.rules (v5.33 host-network)"
        elif grep -q "BEGIN VLESS REALITY DOCKER FORWARDING RULES" /etc/ufw/after.rules; then
            log_success "Docker forwarding rules found in /etc/ufw/after.rules (legacy marker)"
        else
            log_warning "FAMILYTRAFFIC DOCKER FORWARDING rules section not found in /etc/ufw/after.rules"
        fi
    else
        log_warning "/etc/ufw/after.rules file not found"
    fi

    # Check iptables NAT rules
    if command -v iptables &>/dev/null; then
        if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
            log_success "iptables MASQUERADE rule active"
        else
            log_warning "iptables MASQUERADE rule not found (may be normal if UFW hasn't loaded rules yet)"
        fi
    fi

    echo ""
}

# ============================================================================
# Check 7: Container Internet Connectivity
# ============================================================================

verify_container_internet() {
    log_info "Verification 7/10: Testing container internet connectivity..."

    # Use detected DNS if available, otherwise fall back to 8.8.8.8
    local test_dns="${DETECTED_DNS_PRIMARY:-8.8.8.8}"
    local dns_label=""

    # Determine DNS provider name for informative output
    case "$test_dns" in
        "1.1.1.1") dns_label="Cloudflare DNS" ;;
        "8.8.8.8") dns_label="Google DNS" ;;
        "9.9.9.9") dns_label="Quad9 DNS" ;;
        "77.88.8.8") dns_label="Yandex DNS (Primary)" ;;
        "77.88.8.1") dns_label="Yandex DNS (Secondary)" ;;
        *) dns_label="Custom DNS" ;;
    esac

    # Display which DNS is being used for testing
    if [[ -n "${DETECTED_DNS_PRIMARY:-}" ]]; then
        log_info "  Using auto-detected DNS: ${test_dns} (${dns_label})"
    else
        log_info "  DNS auto-detection not configured, using fallback: ${test_dns} (${dns_label})"
    fi
    echo ""

    # [1/4] Test connectivity from xray container using detected DNS
    log_info "  [1/4] Testing xray container internet connectivity..."
    if docker exec familytraffic ping -c 3 -W 5 "$test_dns" &>/dev/null; then
        log_success "Container 'familytraffic' can reach internet (ping ${test_dns})"
    else
        log_error "Container 'familytraffic' cannot reach internet (ping ${test_dns} failed)"
        log_warning "  This may indicate UFW Docker forwarding issue"
        log_warning "  Check: sudo ufw status | grep DOCKER"
    fi
    echo ""

    # [2/4] Test DNS resolution from xray container
    log_info "  [2/4] Testing DNS resolution capability..."
    if docker exec familytraffic ping -c 3 -W 5 google.com &>/dev/null; then
        log_success "Container 'familytraffic' has DNS resolution"
    else
        log_error "Container 'familytraffic' cannot resolve DNS (ping google.com failed)"
        log_warning "  This may indicate DNS server unavailability"
        log_warning "  Current DNS: ${test_dns}"
    fi
    echo ""

    # [3/4] Test connectivity from nginx container (if exists)
    if docker ps --format '{{.Names}}' | grep -q '^familytraffic$'; then
        log_info "  [3/4] Testing nginx reverse proxy container..."
        if docker exec familytraffic ping -c 3 -W 5 "$test_dns" &>/dev/null; then
            log_success "Container 'familytraffic' can reach internet (ping ${test_dns})"
        else
            log_error "Container 'familytraffic' cannot reach internet (ping ${test_dns} failed)"
        fi
        echo ""
    fi

    # [4/4] Test connection to Reality destination
    log_info "  [4/4] Testing Reality destination connectivity..."
    local dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$VLESS_HOME/config/xray_config.json" 2>/dev/null || echo "")
    if [[ -n "$dest" && "$dest" != "null" ]]; then
        local dest_host=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)

        if docker exec familytraffic timeout 5 bash -c "echo > /dev/tcp/$dest_host/$dest_port" 2>/dev/null; then
            log_success "Container can reach Reality destination: $dest"
        else
            log_warning "Container cannot reach Reality destination: $dest"
            log_warning "  This may be normal if destination requires TLS handshake"
            log_warning "  Xray will handle the connection during normal operation"
        fi
    else
        log_warning "Reality destination not configured, skipping connectivity test"
    fi

    echo ""
}

# ============================================================================
# Check 8: Port Listening
# ============================================================================

verify_port_listening() {
    log_info "Verification 8/10: Checking port listening status..."

    local vless_port=$(jq -r '.inbounds[0].port' "$VLESS_HOME/config/xray_config.json" 2>/dev/null || echo "443")

    # Check if port is listening on host (v5.33: Nginx stream on 443, Xray on 8443 internal)
    if [[ "$vless_port" == "8443" ]]; then
        # v5.33 architecture: Port 8443 is internal (container-only), check port 443 instead
        if ss -tuln | grep -q ":443 "; then
            log_success "Port 443 is listening on host (Nginx stream frontend)"
            log_info "  Port 8443 is container-internal only (not on host) - expected for v5.33"
        elif netstat -tuln 2>/dev/null | grep -q ":443 "; then
            log_success "Port 443 is listening on host (Nginx stream frontend)"
            log_info "  Port 8443 is container-internal only (not on host) - expected for v5.33"
        else
            log_error "Port 443 is not listening on host (Nginx stream not running)"
        fi
    else
        # Legacy architecture or custom port
        if ss -tuln | grep -q ":${vless_port} "; then
            log_success "Port $vless_port is listening on host"
        elif netstat -tuln 2>/dev/null | grep -q ":${vless_port} "; then
            log_success "Port $vless_port is listening on host"
        else
            log_error "Port $vless_port is not listening on host"
        fi
    fi

    # v5.33: familytraffic runs in host network mode — ports 443/1080/8118 bound directly on host
    # (no Docker port mapping; ss check above is sufficient)
    log_info "  Container 'familytraffic' uses host network — port binding via host network stack"

    # Check if port is accessible from outside (basic check)
    local server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
    if [[ "$server_ip" != "unknown" ]]; then
        log_info "Server public IP: $server_ip"
    fi

    echo ""
}

# ============================================================================
# Display Summary
# ============================================================================

display_verification_summary() {
    echo "======================================================================"
    echo "  Verification Summary"
    echo "======================================================================"
    echo ""

    if [[ "$VERIFICATION_PASSED" == "true" ]]; then
        log_success "ALL VERIFICATIONS PASSED"
        echo ""
        echo "Your VLESS Reality installation is ready to use!"
        echo ""
        echo "Next steps:"
        echo "  1. Create your first user:"
        echo "     sudo /opt/familytraffic/vless add-user <username>"
        echo ""
        echo "  2. View service status:"
        echo "     docker ps | grep vless"
        echo ""
        echo "  3. Check logs:"
        echo "     docker compose -f /opt/familytraffic/docker-compose.yml logs"
        echo ""
    else
        log_error "VERIFICATION FAILED (${#VERIFICATION_ERRORS[@]} errors)"
        echo ""
        echo "Errors encountered:"
        for error in "${VERIFICATION_ERRORS[@]}"; do
            echo "  - $error"
        done
        echo ""
        echo "Please review the errors above and fix them before proceeding."
        echo ""
        echo "Common fixes:"
        echo "  1. Container issues: docker compose -f /opt/familytraffic/docker-compose.yml up -d"
        echo "  2. Permission issues: Run the installation script again as root"
        echo "  3. Network issues: Check UFW Docker forwarding configuration"
        echo ""
    fi

    echo "======================================================================"
    echo ""
}

# ============================================================================
# FUNCTION: validate_mandatory_tls
# ============================================================================
# Description: Validate TLS configuration for public proxy mode (v3.3)
# Checks:
#   - streamSettings.security="tls" for SOCKS5/HTTP inbounds
#   - Certificate files exist and accessible
#   - Docker volume mount configured
# Returns: 0 if valid, 1 if validation fails
# Related: TASK-2.4 (v3.3 TLS Validation)
# ============================================================================
validate_mandatory_tls() {
    echo ""
    log_info "Verification 5.6/10: Validating TLS encryption (v5.33 Nginx stream architecture)..."

    # Only validate if public proxy mode enabled
    if [[ "${ENABLE_PUBLIC_PROXY:-false}" != "true" ]]; then
        log_info "  ⊗ Public proxy disabled, skipping TLS validation"
        echo ""
        return 0
    fi

    local validation_failed=0

    # Check 1: nginx.conf exists (v5.33: Nginx stream replaces HAProxy)
    log_info "  [1/5] Checking Nginx stream configuration file..."
    if [[ ! -f "${INSTALL_ROOT}/config/nginx/nginx.conf" ]]; then
        log_error "    ✗ nginx.conf not found: ${INSTALL_ROOT}/config/nginx/nginx.conf"
        validation_failed=1
    else
        log_success "    ✓ nginx.conf exists"
    fi

    # Check 2: familytraffic container running
    log_info "  [2/5] Checking familytraffic container..."
    local ft_status
    ft_status=$(docker inspect familytraffic -f '{{.State.Status}}' 2>/dev/null || echo "not-found")
    if [[ "$ft_status" == "running" ]]; then
        log_success "    ✓ familytraffic container running"
    else
        log_error "    ✗ familytraffic container status: $ft_status"
        validation_failed=1
    fi

    # Check 3: Certificate files exist
    log_info "  [3/5] Checking Let's Encrypt certificates..."
    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "    ✗ DOMAIN variable not set"
        validation_failed=1
    elif [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        log_error "    ✗ Certificate not found: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        validation_failed=1
    else
        log_success "    ✓ Certificates exist for $DOMAIN"
        local expiry_date
        expiry_date=$(openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
        log_info "    ℹ Expires: $expiry_date"
    fi

    # Check 4: Xray inbounds listen on 127.0.0.1 (v5.33 single-container: Nginx and Xray share localhost)
    log_info "  [4/5] Checking Xray proxy inbounds (should be 127.0.0.1)..."
    local config_file="${INSTALL_ROOT}/config/xray_config.json"
    local socks5_listen
    local http_listen
    socks5_listen=$(jq -r '.inbounds[] | select(.tag=="socks5-proxy") | .listen' "$config_file" 2>/dev/null)
    http_listen=$(jq -r '.inbounds[] | select(.tag=="http-proxy") | .listen' "$config_file" 2>/dev/null)

    if [[ "$socks5_listen" == "127.0.0.1" ]] && [[ "$http_listen" == "127.0.0.1" ]]; then
        log_success "    ✓ Xray proxies listen on 127.0.0.1 (correct for single-container)"
    else
        log_error "    ✗ Xray proxies should listen on 127.0.0.1 (single-container, Nginx forwards locally)"
        log_error "    Found: SOCKS5=$socks5_listen, HTTP=$http_listen"
        validation_failed=1
    fi

    # Check 5: Nginx stream ports accessible
    log_info "  [5/5] Checking Nginx stream port accessibility..."
    # Wait for Nginx to fully bind to all ports (prevent race condition)
    sleep 2
    local nginx_listening=0
    # Use awk to extract port column and match exact port number (works with IPv4/IPv6)
    if ss -tuln | awk '{print $5}' | grep -qE ':443$'; then
        nginx_listening=$((nginx_listening + 1))
    fi
    if ss -tuln | awk '{print $5}' | grep -qE ':1080$'; then
        nginx_listening=$((nginx_listening + 1))
    fi
    if ss -tuln | awk '{print $5}' | grep -qE ':8118$'; then
        nginx_listening=$((nginx_listening + 1))
    fi

    if [[ $nginx_listening -eq 3 ]]; then
        log_success "    ✓ Nginx stream listening on ports 443, 1080, 8118"
    else
        log_error "    ✗ Nginx stream not listening on all required ports (found $nginx_listening/3)"
        validation_failed=1
    fi

    # Final result
    echo ""
    if [[ $validation_failed -eq 0 ]]; then
        log_success "TLS validation: PASSED (v5.33 Nginx stream architecture)"
        log_info "  • Architecture: Client → Nginx stream (TLS/SNI passthrough) → Xray (127.0.0.1)"
        log_info "  • Port 443: SNI routing (VLESS Reality passthrough)"
        log_info "  • Port 1080: SOCKS5 TLS termination → 127.0.0.1:10800"
        log_info "  • Port 8118: HTTP TLS termination → 127.0.0.1:18118"
        return 0
    else
        log_error "TLS validation: FAILED"
        log_error "v5.33 requires Nginx stream for unified TLS termination"
        return 1
    fi
}

# ============================================================================
# FUNCTION: test_xray_config
# ============================================================================
# Description: Test Xray configuration for syntax and validity
# Uses: xray run -test command
# Returns: 0 if valid, 1 if test fails
# Related: TASK-2.5 (v3.3 Config Test)
# ============================================================================
test_xray_config() {
    echo ""
    log_info "Verification 5.5/10: Testing Xray configuration..."

    local config_file="${INSTALL_ROOT}/config/xray_config.json"

    # Check 1: JSON syntax validation
    log_info "  [1/2] Validating JSON syntax..."
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "    ✗ Invalid JSON syntax in $config_file"
        log_error "    Run: jq . $config_file"
        return 1
    fi
    log_success "    ✓ JSON syntax valid"

    # Check 2: Xray test mode
    log_info "  [2/2] Running Xray configuration test..."

    # Prepare volume mounts for test
    # Mount config file directly (xray_config.json -> /etc/xray/config.json)
    local volume_args="-v ${INSTALL_ROOT}/config/xray_config.json:/etc/xray/config.json:ro"

    # Add certificate volume if public proxy enabled
    if [[ "${ENABLE_PUBLIC_PROXY:-false}" == "true" ]]; then
        volume_args="$volume_args -v /etc/letsencrypt:/certs:ro"
    fi

    # Run xray test
    local test_output
    if test_output=$(docker run --rm $volume_args "${XRAY_IMAGE}" xray run -test -c /etc/xray/config.json 2>&1); then
        log_success "    ✓ Xray configuration test passed"
        return 0
    else
        log_error "    ✗ Xray configuration test failed"
        log_error "Test output:"
        echo "$test_output" | while IFS= read -r line; do
            log_error "    $line"
        done
        return 1
    fi
}

# ============================================================================
# Export Functions
# ============================================================================

# Export all functions for use by other scripts
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced
    export -f verify_installation
    export -f verify_directory_structure
    export -f verify_file_permissions
    export -f verify_network_mode
    export -f verify_containers
    export -f verify_xray_config
    export -f verify_ufw_rules
    export -f verify_container_internet
    export -f verify_port_listening
    export -f display_verification_summary
    export -f validate_mandatory_tls
    export -f test_xray_config
    export -f log_info
    export -f log_success
    export -f log_warning
    export -f log_error
fi

# ============================================================================
# Main Execution (if run directly)
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly
    verify_installation
fi
