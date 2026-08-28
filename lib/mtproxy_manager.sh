#!/bin/bash
# ============================================================================
# VLESS Reality Deployment System
# Module: MTProxy Manager
# Version: 7.0.0 (mtg v2 + supervisord integration)
# ============================================================================
#
# Purpose:
#   MTProxy management system for Telegram proxy functionality. Handles
#   MTProxy configuration via mtg v2 (nineseconds/mtg), supervisord lifecycle
#   inside the familytraffic single container, UFW rules, and nginx cloak-port.
#
# Functions:
#   1. mtproxy_init()                      - Initialize MTProxy directory structure
#   2. mtproxy_start()                     - Start mtg via supervisorctl
#   3. mtproxy_stop()                      - Stop mtg via supervisorctl
#   4. mtproxy_restart()                   - Restart mtg via supervisorctl
#   5. mtproxy_status()                    - Show MTProxy status
#   6. generate_mtproxy_secret_file()      - Generate proxy-secret file from secrets.json
#   7. mtproxy_is_installed()              - Check if MTProxy is installed
#   8. mtproxy_is_running()               - Check if mtg is running via supervisord
#   9. generate_mtg_toml()                - Generate /config/mtproxy/mtg.toml for mtg v2
#   10. mtg_supervisord_start()            - Start mtg via docker exec supervisorctl
#   11. mtg_supervisord_stop()             - Stop mtg via docker exec supervisorctl
#   12. mtg_supervisord_restart()          - Restart mtg via docker exec supervisorctl
#   13. mtg_supervisord_status()           - Show mtg supervisord status
#   14. mtg_supervisord_enable()           - Create supervisord.d/mtg.conf (autostart=true)
#   15. mtg_supervisord_disable_config()   - Remove supervisord.d/mtg.conf (disable autostart)
#   16. mtg_ufw_allow()                    - Open port 2053/tcp in UFW
#   17. mtg_ufw_deny()                     - Close port 2053/tcp in UFW
#
# Usage:
#   source lib/mtproxy_manager.sh
#   mtproxy_init 2053
#   generate_mtg_toml "proxy.example.com"
#   mtg_supervisord_start
#   mtproxy_status
#
# Dependencies:
#   - jq (JSON processing)
#   - docker (container management)
#   - curl (stats endpoint access)
#   - lib/mtproxy_secret_manager.sh (secret generation)
#
# Author: VLESS Development Team
# Date: 2025-11-08 / Updated: 2026-03-12
# ============================================================================

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

# Installation paths (only define if not already set)
[[ -z "${VLESS_HOME:-}" ]] && readonly VLESS_HOME="/opt/familytraffic"
[[ -z "${MTPROXY_CONFIG_DIR:-}" ]] && readonly MTPROXY_CONFIG_DIR="${VLESS_HOME}/config/mtproxy"
[[ -z "${MTPROXY_DATA_DIR:-}" ]] && readonly MTPROXY_DATA_DIR="${VLESS_HOME}/data/mtproxy"
[[ -z "${MTPROXY_LOGS_DIR:-}" ]] && readonly MTPROXY_LOGS_DIR="${VLESS_HOME}/logs/mtproxy"

# MTProxy configuration files
[[ -z "${MTPROXY_SECRETS_JSON:-}" ]] && readonly MTPROXY_SECRETS_JSON="${MTPROXY_CONFIG_DIR}/secrets.json"
[[ -z "${MTPROXY_SECRET_FILE:-}" ]] && readonly MTPROXY_SECRET_FILE="${MTPROXY_CONFIG_DIR}/proxy-secret"

# Main familytraffic container (supervisord-based mtg v2)
[[ -z "${FAMILYTRAFFIC_CONTAINER:-}" ]] && readonly FAMILYTRAFFIC_CONTAINER="familytraffic"

# Default ports
# MTPROXY_PORT=2053 (public MTProxy port via mtg v2 Fake TLS)
[[ -z "${MTPROXY_PORT:-}" ]] && readonly MTPROXY_PORT="${MTPROXY_PORT:-2053}"

# mtg v2 configuration
[[ -z "${MTG_CONFIG_FILE:-}" ]] && readonly MTG_CONFIG_FILE="${MTPROXY_CONFIG_DIR}/mtg.toml"
[[ -z "${MTG_CLOAK_PORT:-}" ]] && readonly MTG_CLOAK_PORT="${MTG_CLOAK_PORT:-4443}"

# supervisord dynamic programs directory (host-side, mounted :ro into container)
# mtg.conf placed here enables autostart=true for mtg on container restarts
[[ -z "${SUPERVISORD_D_DIR:-}" ]] && readonly SUPERVISORD_D_DIR="${VLESS_HOME}/config/supervisord.d"
[[ -z "${MTG_SUPERVISORD_CONF:-}" ]] && readonly MTG_SUPERVISORD_CONF="${SUPERVISORD_D_DIR}/mtg.conf"

# Colors for output (only define if not already set to avoid conflicts)
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================

mtproxy_log_info() {
    echo -e "${BLUE}[MTProxy INFO]${NC} $*"
}

mtproxy_log_success() {
    echo -e "${GREEN}[MTProxy ✓]${NC} $*"
}

mtproxy_log_warning() {
    echo -e "${YELLOW}[MTProxy ⚠]${NC} $*"
}

mtproxy_log_error() {
    echo -e "${RED}[MTProxy ✗]${NC} $*" >&2
}

# ============================================================================
# FUNCTION: mtproxy_init
# ============================================================================
# Description: Initialize MTProxy directory structure and base configuration
#
# Parameters:
#   $1 - port (default: 8443)
#   $2 - workers (default: 2)
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   mtproxy_init 8443 2
# ============================================================================
mtproxy_init() {
    mtproxy_log_info "Initializing MTProxy directory structure..."

    # Create directories
    mkdir -p "${MTPROXY_CONFIG_DIR}" || {
        mtproxy_log_error "Failed to create config directory: ${MTPROXY_CONFIG_DIR}"
        return 1
    }

    mkdir -p "${MTPROXY_DATA_DIR}" || {
        mtproxy_log_error "Failed to create data directory: ${MTPROXY_DATA_DIR}"
        return 1
    }

    mkdir -p "${MTPROXY_LOGS_DIR}" || {
        mtproxy_log_error "Failed to create logs directory: ${MTPROXY_LOGS_DIR}"
        return 1
    }

    # Set permissions
    chmod 755 "${MTPROXY_CONFIG_DIR}"
    chmod 755 "${MTPROXY_DATA_DIR}"
    chmod 755 "${MTPROXY_LOGS_DIR}"

    # Initialize secrets.json (empty structure)
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        cat > "${MTPROXY_SECRETS_JSON}" <<'EOF'
{
  "version": "1.0",
  "secrets": []
}
EOF
        chmod 600 "${MTPROXY_SECRETS_JSON}"
    fi

    mtproxy_log_success "MTProxy directories initialized"
    mtproxy_log_info "  Config: ${MTPROXY_CONFIG_DIR}"
    mtproxy_log_info "  Data:   ${MTPROXY_DATA_DIR}"
    mtproxy_log_info "  Logs:   ${MTPROXY_LOGS_DIR}"

    return 0
}

# ============================================================================
# FUNCTION: generate_mtproxy_secret_file
# ============================================================================
# Description: Generate proxy-secret file from secrets.json (v6.0/v6.1 compatible)
#
# Parameters:
#   None (reads from secrets.json)
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   generate_mtproxy_secret_file
#
# Note:
#   - v6.0: Single secret (first entry in secrets.json)
#   - v6.1: Multi-user secrets (all entries in secrets.json, one per line)
# ============================================================================
generate_mtproxy_secret_file() {
    mtproxy_log_info "Generating proxy-secret file from secrets.json..."

    # Verify secrets.json exists
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        mtproxy_log_error "Secrets file not found: ${MTPROXY_SECRETS_JSON}"
        return 1
    fi

    # Extract secrets array
    local secrets_count
    secrets_count=$(jq -r '.secrets | length' "${MTPROXY_SECRETS_JSON}" 2>/dev/null)

    if [[ -z "$secrets_count" ]] || [[ "$secrets_count" == "null" ]]; then
        mtproxy_log_error "Failed to read secrets from ${MTPROXY_SECRETS_JSON}"
        return 1
    fi

    if [[ "$secrets_count" -eq 0 ]]; then
        mtproxy_log_error "No secrets found in secrets.json (run 'familytraffic-mtproxy add-secret' first)"
        return 1
    fi

    # Create backup if file exists
    if [[ -f "${MTPROXY_SECRET_FILE}" ]]; then
        cp "${MTPROXY_SECRET_FILE}" "${MTPROXY_SECRET_FILE}.bak"
    fi

    # Generate proxy-secret file (one secret per line for MTProxy multi-user support)
    # v6.0: single secret (first line only)
    # v6.1: multi-user (multiple lines)
    {
        for ((i=0; i<secrets_count; i++)); do
            local secret
            secret=$(jq -r ".secrets[${i}].secret" "${MTPROXY_SECRETS_JSON}")

            if [[ -n "$secret" ]] && [[ "$secret" != "null" ]]; then
                echo "$secret"
            fi
        done
    } > "${MTPROXY_SECRET_FILE}"

    # Validate file
    if [[ ! -f "${MTPROXY_SECRET_FILE}" ]]; then
        mtproxy_log_error "Failed to create ${MTPROXY_SECRET_FILE}"

        # Restore backup
        if [[ -f "${MTPROXY_SECRET_FILE}.bak" ]]; then
            mv "${MTPROXY_SECRET_FILE}.bak" "${MTPROXY_SECRET_FILE}"
        fi

        return 1
    fi

    # Set strict permissions (MTProxy secret file)
    chmod 600 "${MTPROXY_SECRET_FILE}"
    chown root:root "${MTPROXY_SECRET_FILE}" 2>/dev/null || true

    mtproxy_log_success "proxy-secret file generated"
    mtproxy_log_info "  File: ${MTPROXY_SECRET_FILE}"
    mtproxy_log_info "  Secrets count: ${secrets_count}"

    return 0
}

# ============================================================================
# FUNCTION: mtproxy_start
# ============================================================================
# Description: Start mtg via supervisorctl inside familytraffic container.
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   mtproxy_start
# ============================================================================
mtproxy_start() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        mtproxy_log_error "Container '${FAMILYTRAFFIC_CONTAINER}' is not running (docker compose up -d)"
        return 1
    fi
    mtg_supervisord_start
}

# ============================================================================
# FUNCTION: mtproxy_stop
# ============================================================================
# Description: Stop mtg via supervisorctl inside familytraffic container.
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   mtproxy_stop
# ============================================================================
mtproxy_stop() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        mtproxy_log_error "Container '${FAMILYTRAFFIC_CONTAINER}' is not running"
        return 1
    fi
    mtg_supervisord_stop
}

# ============================================================================
# FUNCTION: mtproxy_restart
# ============================================================================
# Description: Restart mtg via supervisorctl inside familytraffic container.
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   mtproxy_restart
# ============================================================================
mtproxy_restart() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        mtproxy_log_error "Container '${FAMILYTRAFFIC_CONTAINER}' is not running"
        return 1
    fi
    mtg_supervisord_restart
}

# ============================================================================
# FUNCTION: mtproxy_status
# ============================================================================
# Description: Show MTProxy status via supervisorctl inside familytraffic container.
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   mtproxy_status
# ============================================================================
mtproxy_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              MTProxy Status (mtg v2)                         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if ! docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        echo -e "${RED}Status:${NC} container '${FAMILYTRAFFIC_CONTAINER}' is not running"
        echo ""
        echo -e "${BLUE}To start:${NC} docker compose up -d"
        return 1
    fi

    local supervisord_status
    supervisord_status=$(docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf status mtg 2>/dev/null || true)

    if echo "$supervisord_status" | grep -q "RUNNING"; then
        echo -e "${GREEN}Status:${NC} RUNNING"
    elif echo "$supervisord_status" | grep -q "STOPPED"; then
        echo -e "${YELLOW}Status:${NC} STOPPED"
    else
        echo -e "${YELLOW}Status:${NC} ${supervisord_status:-UNKNOWN}"
    fi

    # Show mtg.toml config
    if [[ -f "${MTG_CONFIG_FILE}" ]]; then
        local secret bind_to
        secret=$(grep '^secret' "${MTG_CONFIG_FILE}" 2>/dev/null | cut -d'"' -f2 | head -1)
        bind_to=$(grep '^bind-to' "${MTG_CONFIG_FILE}" 2>/dev/null | cut -d'"' -f2 | head -1)
        echo -e "${BLUE}Port:${NC}   ${bind_to:-${MTPROXY_PORT}}"
        echo -e "${BLUE}Secret:${NC} ${secret:0:12}... (ee Fake TLS)"
        echo -e "${BLUE}Config:${NC} ${MTG_CONFIG_FILE}"
    fi

    # Get secrets count
    if [[ -f "${MTPROXY_SECRETS_JSON}" ]]; then
        local secrets_count
        secrets_count=$(jq -r '.secrets | length' "${MTPROXY_SECRETS_JSON}" 2>/dev/null || echo "0")
        echo -e "${BLUE}Secrets:${NC} ${secrets_count}"
    fi

    echo ""
    return 0
}

# ============================================================================
# FUNCTION: mtproxy_is_installed
# ============================================================================
# Description: Check if MTProxy is installed (v7.0: checks config directory)
#
# Parameters:
#   None
#
# Returns:
#   0 if installed, 1 if not
#
# Example:
#   if mtproxy_is_installed; then echo "Installed"; fi
# ============================================================================
mtproxy_is_installed() {
    [[ -d "${MTPROXY_CONFIG_DIR}" ]] && [[ -f "${MTG_CONFIG_FILE}" ]]
}

# ============================================================================
# FUNCTION: mtproxy_is_running
# ============================================================================
# Description: Check if mtg is running via supervisorctl in familytraffic container.
#
# Parameters:
#   None
#
# Returns:
#   0 if running, 1 if not
#
# Example:
#   if mtproxy_is_running; then echo "Running"; fi
# ============================================================================
mtproxy_is_running() {
    docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf status mtg 2>/dev/null | grep -q "RUNNING"
}

# ============================================================================
# FUNCTION: get_server_ip (v6.1)
# ============================================================================
# Description: Get server's public IP address
#
# Parameters:
#   None
#
# Returns:
#   Stdout: IP address
#   Exit: 0 on success, 1 on failure
#
# Example:
#   server_ip=$(get_server_ip)
# ============================================================================
get_server_ip() {
    local ip=""

    # Method 1: Try ip route (most reliable for VPS)
    if command -v ip &>/dev/null; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' | head -1)
    fi

    # Method 2: Try hostname -I (fallback)
    if [[ -z "$ip" ]] && command -v hostname &>/dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 3: Try external IP detection (last resort)
    if [[ -z "$ip" ]]; then
        # Try multiple services for reliability
        for service in "ifconfig.me" "icanhazip.com" "ipinfo.io/ip"; do
            ip=$(curl -s --max-time 5 "https://${service}" 2>/dev/null | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
            if [[ -n "$ip" ]]; then
                break
            fi
        done
    fi

    if [[ -z "$ip" ]]; then
        mtproxy_log_error "Failed to detect server IP"
        return 1
    fi

    echo "$ip"
    return 0
}

# ============================================================================
# FUNCTION: generate_mtproxy_deeplink (v6.1)
# ============================================================================
# Description: Generate Telegram MTProxy deep link for user
#
# Parameters:
#   $1 - username (string)
#   $2 - server_ip (optional, auto-detected if not provided)
#
# Returns:
#   Stdout: tg://proxy?server=IP&port=8443&secret=HEX
#   Exit: 0 on success, 1 on failure
#
# Example:
#   deeplink=$(generate_mtproxy_deeplink "alice")
#   deeplink=$(generate_mtproxy_deeplink "alice" "203.0.113.1")
#
# Format:
#   tg://proxy?server=IP&port=PORT&secret=SECRET
# ============================================================================
generate_mtproxy_deeplink() {
    local username="$1"
    local server_ip="${2:-}"

    # Validate username
    if [[ -z "$username" ]]; then
        mtproxy_log_error "Username required"
        return 1
    fi

    # Get user info from users.json
    local users_json="/opt/familytraffic/data/users.json"
    if [[ ! -f "$users_json" ]]; then
        mtproxy_log_error "Users database not found: $users_json"
        return 1
    fi

    # Extract MTProxy secret for user
    local mtproxy_secret
    mtproxy_secret=$(jq -r --arg user "$username" '.users[] | select(.username == $user) | .mtproxy_secret' "$users_json" 2>/dev/null)

    if [[ -z "$mtproxy_secret" ]] || [[ "$mtproxy_secret" == "null" ]]; then
        mtproxy_log_error "User '$username' has no MTProxy secret"
        mtproxy_log_info "To add MTProxy secret: vless add-user $username (during creation)"
        return 1
    fi

    # Get server IP if not provided
    if [[ -z "$server_ip" ]]; then
        server_ip=$(get_server_ip)
        if [[ -z "$server_ip" ]]; then
            return 1
        fi
    fi

    local mtproxy_port="${MTPROXY_PORT}"

    # Generate deep link
    local deeplink="tg://proxy?server=${server_ip}&port=${mtproxy_port}&secret=${mtproxy_secret}"

    echo "$deeplink"
    return 0
}

# ============================================================================
# FUNCTION: generate_mtproxy_qrcode (v6.1)
# ============================================================================
# Description: Generate QR code PNG for MTProxy deep link
#
# Parameters:
#   $1 - username (string)
#   $2 - output_file (optional, default: /opt/familytraffic/data/clients/<username>/mtproxy_qr.png)
#
# Returns:
#   Exit: 0 on success, 1 on failure
#
# Example:
#   generate_mtproxy_qrcode "alice"
#   generate_mtproxy_qrcode "alice" "/tmp/alice_mtproxy.png"
#
# Dependencies:
#   - qrencode package (apt install qrencode)
# ============================================================================
generate_mtproxy_qrcode() {
    local username="$1"
    local output_file="${2:-}"

    # Validate username
    if [[ -z "$username" ]]; then
        mtproxy_log_error "Username required"
        return 1
    fi

    # Check if qrencode is available
    if ! command -v qrencode &>/dev/null; then
        mtproxy_log_error "qrencode not found"
        mtproxy_log_info "Install with: sudo apt install qrencode"
        return 1
    fi

    # Set default output file if not provided
    if [[ -z "$output_file" ]]; then
        local user_dir="/opt/familytraffic/data/clients/${username}"
        if [[ ! -d "$user_dir" ]]; then
            mkdir -p "$user_dir"
            chmod 700 "$user_dir"
        fi
        output_file="${user_dir}/mtproxy_qr.png"
    fi

    # Generate deep link
    local deeplink
    deeplink=$(generate_mtproxy_deeplink "$username")
    if [[ -z "$deeplink" ]]; then
        return 1
    fi

    # Generate QR code (300x300px, high error correction)
    if ! qrencode -o "$output_file" -s 10 -l H "$deeplink" 2>/dev/null; then
        mtproxy_log_error "Failed to generate QR code"
        return 1
    fi

    # Set permissions
    chmod 600 "$output_file"

    mtproxy_log_success "QR code generated: $output_file"
    return 0
}

# ============================================================================
# FUNCTION: show_mtproxy_config (v6.1)
# ============================================================================
# Description: Display MTProxy configuration for user
#
# Parameters:
#   $1 - username (string)
#
# Returns:
#   Exit: 0 on success, 1 on failure
#
# Example:
#   show_mtproxy_config "alice"
# ============================================================================
show_mtproxy_config() {
    local username="$1"

    # Validate username
    if [[ -z "$username" ]]; then
        mtproxy_log_error "Username required"
        return 1
    fi

    # Get user info from users.json
    local users_json="/opt/familytraffic/data/users.json"
    if [[ ! -f "$users_json" ]]; then
        mtproxy_log_error "Users database not found: $users_json"
        return 1
    fi

    # Extract user data
    local user_data
    user_data=$(jq -r --arg user "$username" '.users[] | select(.username == $user)' "$users_json" 2>/dev/null)

    if [[ -z "$user_data" ]]; then
        mtproxy_log_error "User not found: $username"
        return 1
    fi

    # Extract MTProxy fields
    local mtproxy_secret mtproxy_secret_type mtproxy_domain
    mtproxy_secret=$(echo "$user_data" | jq -r '.mtproxy_secret // "null"')
    mtproxy_secret_type=$(echo "$user_data" | jq -r '.mtproxy_secret_type // "null"')
    mtproxy_domain=$(echo "$user_data" | jq -r '.mtproxy_domain // "null"')

    if [[ "$mtproxy_secret" == "null" ]]; then
        mtproxy_log_error "User '$username' has no MTProxy configuration"
        mtproxy_log_info "To add MTProxy secret: recreate user with MTProxy option enabled"
        return 1
    fi

    # Get server IP
    local server_ip
    server_ip=$(get_server_ip)

    local mtproxy_port="${MTPROXY_PORT}"

    # Generate deep link
    local deeplink
    deeplink=$(generate_mtproxy_deeplink "$username" "$server_ip")

    # Display configuration
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          MTProxy Configuration for: ${username}$(printf '%*s' $((23 - ${#username})) '')║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Server:${NC}       $server_ip"
    echo -e "${BLUE}Port:${NC}         $mtproxy_port"
    echo -e "${BLUE}Secret Type:${NC}  $mtproxy_secret_type"
    if [[ "$mtproxy_domain" != "null" ]]; then
        echo -e "${BLUE}Domain:${NC}       $mtproxy_domain (fake-TLS)"
    fi
    echo -e "${BLUE}Secret:${NC}       ${mtproxy_secret:0:32}..."
    echo ""
    echo -e "${YELLOW}Deep Link:${NC}"
    echo "$deeplink"
    echo ""
    echo -e "${YELLOW}Setup Instructions:${NC}"
    echo "1. Open Telegram on your device"
    echo "2. Click the deep link above (or scan QR code)"
    echo "3. Telegram will prompt to add MTProxy"
    echo "4. Confirm to enable proxy"
    echo ""
    echo -e "${YELLOW}QR Code:${NC}"
    echo "Generate QR code: mtproxy generate-qr $username"
    echo ""

    return 0
}

# ============================================================================
# FUNCTION: regenerate_mtproxy_secret_file_from_users (v6.1)
# ============================================================================
# Description: Regenerate MTProxy proxy-secret file from users.json database
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   regenerate_mtproxy_secret_file_from_users
#
# Notes:
#   - Reads users.json (/opt/familytraffic/data/users.json)
#   - Extracts users with mtproxy_secret != null
#   - Generates proxy-secret file (one secret per line)
#   - Updates mtproxy_config.json (multi_user: true if > 1 secret)
# ============================================================================
regenerate_mtproxy_secret_file_from_users() {
    mtproxy_log_info "Regenerating MTProxy secret file from users.json..."

    # Verify users.json exists
    local users_json="/opt/familytraffic/data/users.json"
    if [[ ! -f "$users_json" ]]; then
        mtproxy_log_error "Users database not found: $users_json"
        return 1
    fi

    # Extract users with MTProxy secrets
    local secrets_array
    secrets_array=$(jq -r '.users[] | select(.mtproxy_secret != null) | .mtproxy_secret' "$users_json" 2>/dev/null)

    if [[ -z "$secrets_array" ]]; then
        mtproxy_log_warning "No users with MTProxy secrets found"
        mtproxy_log_info "To add MTProxy secret: vless add-user <username>"
        return 1
    fi

    # Count secrets
    local secrets_count
    secrets_count=$(echo "$secrets_array" | wc -l)

    if [[ "$secrets_count" -eq 0 ]]; then
        mtproxy_log_warning "No MTProxy secrets found in users database"
        return 1
    fi

    # Create backup if file exists
    if [[ -f "${MTPROXY_SECRET_FILE}" ]]; then
        cp "${MTPROXY_SECRET_FILE}" "${MTPROXY_SECRET_FILE}.bak"
    fi

    # Generate proxy-secret file (one secret per line)
    echo "$secrets_array" > "${MTPROXY_SECRET_FILE}"

    # Validate file
    if [[ ! -f "${MTPROXY_SECRET_FILE}" ]] || [[ ! -s "${MTPROXY_SECRET_FILE}" ]]; then
        mtproxy_log_error "Failed to create ${MTPROXY_SECRET_FILE}"

        # Restore backup
        if [[ -f "${MTPROXY_SECRET_FILE}.bak" ]]; then
            mv "${MTPROXY_SECRET_FILE}.bak" "${MTPROXY_SECRET_FILE}"
        fi

        return 1
    fi

    # Set strict permissions
    chmod 600 "${MTPROXY_SECRET_FILE}"
    chown root:root "${MTPROXY_SECRET_FILE}" 2>/dev/null || true

    mtproxy_log_success "MTProxy secret file regenerated"
    mtproxy_log_info "  File: ${MTPROXY_SECRET_FILE}"
    mtproxy_log_info "  Secrets count: ${secrets_count}"
    mtproxy_log_info "  Multi-user mode: $([ "$secrets_count" -gt 1 ] && echo "YES (v6.1)" || echo "NO (v6.0)")"

    return 0
}

# ============================================================================
# FUNCTION: validate_fake_tls_domain
# ============================================================================
# Description: Validate that a domain is safe to use as an mtg fake-TLS domain.
#
#   Checks performed:
#     1. Domain resolves to at least one A (IPv4) address
#     2. If domain also has AAAA (IPv6) — server must have global IPv6;
#        otherwise mtg will try IPv6 first, time out, and Telegram iOS / strict
#        clients will fail to connect (Telegram Desktop is lenient and may work)
#     3. Domain is reachable on port 443 via IPv4 (fake-TLS relay requires this)
#
# Parameters:
#   $1 - domain (e.g., "vk.com")
#
# Returns:
#   0 - domain is safe to use
#   1 - domain is NOT safe (error printed); caller should abort
#
# Example:
#   validate_fake_tls_domain "vk.com"    # ok, IPv4-only
#   validate_fake_tls_domain "yandex.ru" # error: has AAAA, server has no global IPv6
# ============================================================================
validate_fake_tls_domain() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        mtproxy_log_error "validate_fake_tls_domain: domain is required"
        return 1
    fi

    mtproxy_log_info "Validating fake-TLS domain: ${domain}"

    # ── 1. Resolve IPv4 (A record) ──────────────────────────────────────────
    local ipv4_addrs
    ipv4_addrs=$(getent ahostsv4 "$domain" 2>/dev/null \
        | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)

    if [[ -z "$ipv4_addrs" ]]; then
        mtproxy_log_error "Domain '${domain}' has no A (IPv4) record"
        mtproxy_log_error "Cannot use as fake-TLS domain — choose a domain with IPv4"
        return 1
    fi

    # ── 2. Check whether domain has AAAA (IPv6) records ────────────────────
    local domain_ipv6
    # Filter out loopback (::1), link-local (fe80::), IPv4-mapped (::ffff:)
    domain_ipv6=$(getent ahostsv6 "$domain" 2>/dev/null \
        | awk '{print $1}' \
        | grep -v '^::1$' \
        | grep -v '^fe80' \
        | grep -v '^::ffff:' \
        | sort -u)

    local has_aaaa=false
    [[ -n "$domain_ipv6" ]] && has_aaaa=true

    # ── 3. Check whether THIS server has a global IPv6 address ─────────────
    local server_has_ipv6=false
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        server_has_ipv6=true
    fi

    # ── 4. Fail if domain has IPv6 but server cannot reach it ───────────────
    if [[ "$has_aaaa" == "true" ]] && [[ "$server_has_ipv6" == "false" ]]; then
        mtproxy_log_error "Domain '${domain}' has AAAA (IPv6) records:"
        echo "$domain_ipv6" | while read -r addr; do
            mtproxy_log_error "  ${addr}"
        done
        mtproxy_log_error "This server has NO global IPv6 connectivity."
        mtproxy_log_error "mtg will try IPv6 first → 5 s timeout → fake-TLS handshake fails."
        mtproxy_log_error "iPhone and other strict Telegram clients will hang on 'Connecting...'."
        mtproxy_log_error ""
        mtproxy_log_error "Use a domain with IPv4 only. Suggestions (no AAAA records):"
        mtproxy_log_error "  vk.com  ok.ru  mail.ru  gosuslugi.ru  sberbank.ru"
        return 1
    fi

    # ── 5. Test TCP reachability on port 443 ────────────────────────────────
    local first_ipv4
    first_ipv4=$(echo "$ipv4_addrs" | head -1)
    if ! timeout 5 bash -c "echo > /dev/tcp/${first_ipv4}/443" 2>/dev/null; then
        mtproxy_log_error "Domain '${domain}' (${first_ipv4}):443 is unreachable"
        mtproxy_log_error "mtg needs to connect to the fake-TLS domain to complete the handshake"
        return 1
    fi

    # ── All checks passed ───────────────────────────────────────────────────
    local ipv6_note="has AAAA (server has IPv6 ✓)"
    [[ "$has_aaaa" == "false" ]] && ipv6_note="IPv4-only (no AAAA)"
    mtproxy_log_success "Domain '${domain}': A=${first_ipv4}, ${ipv6_note}, :443 reachable"
    return 0
}

# ============================================================================
# FUNCTION: generate_mtg_toml (v7.0)
# ============================================================================
# Description: Generate mtg.toml configuration for mtg v2 (nineseconds/mtg)
#
# Parameters:
#   $1 - masquerade_domain: domain used as Fake TLS masquerade (e.g., proxy.example.com)
#                           Defaults to reading DOMAIN from /opt/familytraffic/.env
#
# Returns:
#   0 on success, 1 on failure
#
# Notes:
#   - Reads the first ee-type secret from secrets.json
#   - Returns 1 if no ee-secret found (run: familytraffic-mtproxy add-secret --type ee)
#   - Fake TLS secret must start with "ee" prefix
#   - cloak.port references the internal nginx port (4443) for active probing protection
#
# Example:
#   generate_mtg_toml "proxy.example.com"
# ============================================================================
generate_mtg_toml() {
    local masquerade_domain="${1:-}"

    mtproxy_log_info "Generating mtg.toml for mtg v2..."

    # Resolve masquerade domain from .env if not provided
    if [[ -z "$masquerade_domain" ]]; then
        local env_file="${VLESS_HOME}/.env"
        if [[ -f "$env_file" ]]; then
            masquerade_domain=$(grep -E '^DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
        fi
    fi

    if [[ -z "$masquerade_domain" ]]; then
        mtproxy_log_error "masquerade_domain is required (or set DOMAIN in ${VLESS_HOME}/.env)"
        return 1
    fi

    # Ensure config directory exists
    mkdir -p "${MTPROXY_CONFIG_DIR}"

    # Ensure secrets.json exists
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        mtproxy_log_error "secrets.json not found: ${MTPROXY_SECRETS_JSON}"
        mtproxy_log_info "Run: familytraffic-mtproxy add-secret --type ee --domain ${masquerade_domain}"
        return 1
    fi

    # Find first ee-type secret
    local secret
    secret=$(jq -r '.secrets[] | select(.type == "ee" or (.secret | startswith("ee"))) | .secret' \
        "${MTPROXY_SECRETS_JSON}" 2>/dev/null | head -1)

    if [[ -z "$secret" ]] || [[ "$secret" == "null" ]]; then
        mtproxy_log_error "No ee-type secret found in ${MTPROXY_SECRETS_JSON}"
        mtproxy_log_info "MTProxy Fake TLS requires an ee-secret. Run:"
        mtproxy_log_info "  familytraffic-mtproxy add-secret --type ee --domain ${masquerade_domain}"
        return 1
    fi

    # Validate secret starts with "ee"
    if [[ "${secret:0:2}" != "ee" ]]; then
        mtproxy_log_error "Secret must start with 'ee' for Fake TLS: ${secret:0:8}..."
        return 1
    fi

    # Create backup if file exists
    if [[ -f "${MTG_CONFIG_FILE}" ]]; then
        cp "${MTG_CONFIG_FILE}" "${MTG_CONFIG_FILE}.bak"
        mtproxy_log_info "  Backup created: ${MTG_CONFIG_FILE}.bak"
    fi

    # Generate mtg.toml
    cat > "${MTG_CONFIG_FILE}" <<TOML
# mtg.toml — mtg v2 (nineseconds/mtg) configuration
# Generated by lib/mtproxy_manager.sh
# DO NOT EDIT MANUALLY — regenerate via: familytraffic-mtproxy setup

debug = false
secret = "${secret}"

bind-to = "0.0.0.0:${MTPROXY_PORT}"

# Force IPv4 — servers without global IPv6 connectivity fail to reach
# the fake-TLS domain via IPv6 (mtg v2 defaults to prefer-ipv6).
# NOTE: prefer-ip must be at top level, NOT under [network].
prefer-ip = "prefer-ipv4"

# Accept connections from clients whose clock differs from server clock.
# Default 5s is too strict; 3m covers typical Telegram retry cycles and
# environments where the server NTP port (UDP 123) is blocked by the ISP.
tolerate-time-skewness = "3m"

[network]
  # Use plain UDP DNS instead of DoH (requires mtg >= 2.1.12).
  # DoH in older versions may fail to parse responses in some environments.
  dns = "udp://8.8.8.8"

[network.timeout]
  tcp = "5s"

[cloak]
  # Active probing protection: invalid/probe connections are redirected
  # to nginx:${MTG_CLOAK_PORT} which serves real TLS with our LE certificate.
  # Censor sees: valid HTTPS with real content — not a proxy fingerprint.
  port = ${MTG_CLOAK_PORT}
TOML

    chmod 600 "${MTG_CONFIG_FILE}"

    mtproxy_log_success "mtg.toml generated"
    mtproxy_log_info "  File:     ${MTG_CONFIG_FILE}"
    mtproxy_log_info "  Secret:   ${secret:0:8}..."
    mtproxy_log_info "  Port:     ${MTPROXY_PORT}"
    mtproxy_log_info "  Cloak:    ${MTG_CLOAK_PORT} (nginx internal, active probing protection)"
    mtproxy_log_info "  Masquerade: ${masquerade_domain}"

    return 0
}

# ============================================================================
# FUNCTION: mtg_supervisord_start (v7.0)
# ============================================================================
# Description: Start mtg process inside familytraffic container via supervisorctl
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_start() {
    mtproxy_log_info "Starting mtg via supervisorctl..."

    if ! docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf start mtg 2>/dev/null; then
        mtproxy_log_error "Failed to start mtg via supervisorctl in ${FAMILYTRAFFIC_CONTAINER}"
        return 1
    fi

    mtproxy_log_success "mtg started (supervisord)"
    return 0
}

# ============================================================================
# FUNCTION: mtg_supervisord_stop (v7.0)
# ============================================================================
# Description: Stop mtg process inside familytraffic container via supervisorctl
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_stop() {
    mtproxy_log_info "Stopping mtg via supervisorctl..."

    if ! docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf stop mtg 2>/dev/null; then
        mtproxy_log_error "Failed to stop mtg via supervisorctl in ${FAMILYTRAFFIC_CONTAINER}"
        return 1
    fi

    mtproxy_log_success "mtg stopped (supervisord)"
    return 0
}

# ============================================================================
# FUNCTION: mtg_supervisord_restart (v7.0)
# ============================================================================
# Description: Restart mtg process inside familytraffic container via supervisorctl
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_restart() {
    mtproxy_log_info "Restarting mtg via supervisorctl..."

    if ! docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf restart mtg 2>/dev/null; then
        mtproxy_log_error "Failed to restart mtg via supervisorctl in ${FAMILYTRAFFIC_CONTAINER}"
        return 1
    fi

    mtproxy_log_success "mtg restarted (supervisord)"
    return 0
}

# ============================================================================
# FUNCTION: mtg_supervisord_status (v7.0)
# ============================================================================
# Description: Show mtg supervisord status from familytraffic container
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_status() {
    docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf status mtg 2>/dev/null
}

# ============================================================================
# FUNCTION: mtg_supervisord_enable (v7.1)
# ============================================================================
# Description: Enable mtg autostart by creating supervisord.d/mtg.conf on host.
#              supervisord reads this file on container start → mtg autostarts.
#              Also calls supervisorctl reread+update to activate immediately.
#
# Called from: scripts/familytraffic-mtproxy cmd_setup()
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_enable() {
    mtproxy_log_info "Enabling mtg autostart (supervisord.d/mtg.conf)..."

    mkdir -p "${SUPERVISORD_D_DIR}"

    cat > "${MTG_SUPERVISORD_CONF}" << 'EOF'
; MTProxy (mtg v2) — managed by supervisord
; Created by: sudo familytraffic-mtproxy setup
; Removed by: sudo familytraffic-mtproxy disable
; autostart=true ensures mtg starts automatically on container restarts
[program:mtg]
command=/usr/bin/mtg run /opt/familytraffic/config/mtproxy/mtg.toml
priority=4
autostart=true
autorestart=true
startsecs=3
startretries=3
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF

    chmod 644 "${MTG_SUPERVISORD_CONF}"

    # Notify running supervisord: reread detects new conf, update starts mtg (autostart=true)
    if docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf reread 2>/dev/null || true
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf update 2>/dev/null || true
        # Always restart mtg so it picks up the latest mtg.toml from disk.
        # reread+update only starts stopped processes — a running mtg keeps the old config in memory.
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf restart mtg 2>/dev/null || true
    fi

    mtproxy_log_success "mtg enabled (autostart=true on container restarts)"
    return 0
}

# ============================================================================
# FUNCTION: mtg_supervisord_disable_config (v7.1)
# ============================================================================
# Description: Disable mtg autostart by removing supervisord.d/mtg.conf.
#              Also stops mtg in the running container via supervisorctl.
#
# Called from: scripts/familytraffic-mtproxy cmd_disable()
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_supervisord_disable_config() {
    mtproxy_log_info "Disabling mtg autostart (removing supervisord.d/mtg.conf)..."

    # Stop running mtg first
    if docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf stop mtg 2>/dev/null || true
    fi

    # Remove autostart config BEFORE reread so supervisord sees the file is gone
    if [[ -f "${MTG_SUPERVISORD_CONF}" ]]; then
        rm -f "${MTG_SUPERVISORD_CONF}"
        mtproxy_log_success "mtg autostart config removed"
    else
        mtproxy_log_info "mtg autostart config not found (already disabled)"
    fi

    # Notify running supervisord that mtg program is no longer configured
    if docker ps --format '{{.Names}}' | grep -q "^${FAMILYTRAFFIC_CONTAINER}$"; then
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf reread 2>/dev/null || true
        docker exec "${FAMILYTRAFFIC_CONTAINER}" supervisorctl -c /etc/familytraffic/supervisord.conf update 2>/dev/null || true
    fi

    return 0
}

# ============================================================================
# FUNCTION: mtg_ufw_allow (v7.0)
# ============================================================================
# Description: Open port 2053/tcp in UFW (MTProxy public port)
#              Only runs if UFW is active. Called from: familytraffic-mtproxy setup
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_ufw_allow() {
    if ! command -v ufw &>/dev/null; then
        mtproxy_log_info "UFW not found — skipping firewall rule for port ${MTPROXY_PORT}"
        return 0
    fi

    # Check if UFW is active
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        mtproxy_log_info "UFW is inactive — skipping firewall rule for port ${MTPROXY_PORT}"
        return 0
    fi

    # Check if rule already exists
    if ufw status 2>/dev/null | grep -q "${MTPROXY_PORT}/tcp"; then
        mtproxy_log_info "UFW rule for port ${MTPROXY_PORT}/tcp already exists"
        return 0
    fi

    mtproxy_log_info "Opening UFW port ${MTPROXY_PORT}/tcp (MTProxy Fake TLS)..."
    ufw allow "${MTPROXY_PORT}/tcp" comment 'MTProxy Fake TLS (mtg v2)' && ufw reload

    mtproxy_log_success "UFW: port ${MTPROXY_PORT}/tcp allowed"
    return 0
}

# ============================================================================
# FUNCTION: mtg_ufw_deny (v7.0)
# ============================================================================
# Description: Close port 2053/tcp in UFW when MTProxy is disabled
#              Only runs if UFW is active. Called from: mtproxy disable
#
# Returns: 0 on success, 1 on failure
# ============================================================================
mtg_ufw_deny() {
    if ! command -v ufw &>/dev/null; then
        mtproxy_log_info "UFW not found — skipping firewall rule removal"
        return 0
    fi

    # Check if UFW is active
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        mtproxy_log_info "UFW is inactive — skipping firewall rule removal"
        return 0
    fi

    # Check if rule exists
    if ! ufw status 2>/dev/null | grep -q "${MTPROXY_PORT}/tcp"; then
        mtproxy_log_info "UFW rule for port ${MTPROXY_PORT}/tcp not found"
        return 0
    fi

    mtproxy_log_info "Closing UFW port ${MTPROXY_PORT}/tcp..."
    ufw delete allow "${MTPROXY_PORT}/tcp" && ufw reload

    mtproxy_log_success "UFW: port ${MTPROXY_PORT}/tcp denied"
    return 0
}

# ============================================================================
# Module Initialization Complete
# ============================================================================

mtproxy_log_info "MTProxy Manager module loaded (v7.0)"
