#!/bin/bash
# ============================================================================
# VLESS Reality Deployment System
# Module: QR Code Generator
# Version: 1.0.0
# Tasks: EPIC-7 (TASK-7.1 through TASK-7.5)
# ============================================================================
#
# Purpose:
#   Generate QR codes and connection information for VLESS Reality VPN
#   clients. Supports both PNG (400x400px) and ANSI terminal display.
#
# Functions:
#   1. generate_qr_code()             - Generate QR codes (PNG + ANSI)
#   2. generate_qr_png()              - Generate PNG QR code (400x400px)
#   3. display_qr_ansi()              - Display QR code in terminal
#   4. display_connection_info()      - Show connection details
#   5. export_connection_config()     - Export all configs to files
#   6. validate_vless_uri()           - Validate VLESS URI format
#   7. get_server_info()              - Retrieve server configuration
#
# Usage:
#   source lib/qr_generator.sh
#   generate_qr_code "alice" "uuid" "vless://..."
#
# Dependencies:
#   - qrencode (QR code generation)
#   - jq (JSON processing)
#   - curl (IP detection)
#
# Author: Claude Code Agent
# Date: 2025-10-02
# ============================================================================

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

# Installation paths (only define if not already set)
[[ -z "${VLESS_HOME:-}" ]] && readonly VLESS_HOME="/opt/familytraffic"
[[ -z "${XRAY_CONFIG:-}" ]] && readonly XRAY_CONFIG="${VLESS_HOME}/config/xray_config.json"
[[ -z "${CLIENTS_DIR:-}" ]] && readonly CLIENTS_DIR="${VLESS_HOME}/data/clients"
[[ -z "${KEYS_DIR:-}" ]] && readonly KEYS_DIR="${VLESS_HOME}/keys"

# QR Code settings (as per Q-007) - only define if not already set
[[ -z "${QR_PNG_SIZE:-}" ]] && readonly QR_PNG_SIZE=10        # -s 10 = 40 modules * 10 pixels = 400x400px
[[ -z "${QR_PNG_TYPE:-}" ]] && readonly QR_PNG_TYPE="PNG"
[[ -z "${QR_ANSI_TYPE:-}" ]] && readonly QR_ANSI_TYPE="ANSIUTF8"

# Colors for output (only define if not already set to avoid conflicts)
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${MAGENTA:-}" ]] && readonly MAGENTA='\033[0;35m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================

# Logging comes from lib/logger.sh — see the note there on why the output shape
# differs between a terminal and a captured stream.
# shellcheck source=lib/logger.sh
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

# ============================================================================
# TASK-7.5: VLESS URI Validation
# ============================================================================

validate_vless_uri() {
    local uri="$1"

    # Basic format check
    if ! [[ "$uri" =~ ^vless:// ]]; then
        log_error "Invalid URI: Must start with 'vless://'"
        return 1
    fi

    # Check for universally required parameters
    local required_params=("encryption" "security" "sni" "fp" "type")
    for param in "${required_params[@]}"; do
        if ! [[ "$uri" =~ $param= ]]; then
            log_error "Invalid URI: Missing parameter '$param'"
            return 1
        fi
    done

    # Reality-specific parameters: flow, pbk, sid — only required when security=reality
    # Tier 2 transports (WS/XHTTP/gRPC) use security=tls and do not carry these params
    if [[ "$uri" =~ security=reality ]]; then
        for param in flow pbk sid; do
            if ! [[ "$uri" =~ $param= ]]; then
                log_error "Invalid URI: Reality transport requires '$param' parameter"
                return 1
            fi
        done
    fi

    # Validate UUID format
    if ! [[ "$uri" =~ vless://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@ ]]; then
        log_error "Invalid URI: Malformed UUID"
        return 1
    fi

    return 0
}

# ============================================================================
# Get Server Information
# ============================================================================

get_server_info() {
    local -n info_array=$1  # nameref for associative array

    # Get server IP
    info_array[server_ip]=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "SERVER_IP")

    # Get port
    info_array[server_port]=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")

    # Get public key
    if [[ -f "${KEYS_DIR}/public.key" ]]; then
        info_array[public_key]=$(cat "${KEYS_DIR}/public.key" 2>/dev/null || echo "PUBLIC_KEY")
    else
        info_array[public_key]="PUBLIC_KEY"
    fi

    # Get short ID
    info_array[short_id]=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")

    # Get server name (SNI)
    info_array[server_name]=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "www.google.com")

    # Get destination
    info_array[destination]=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG" 2>/dev/null || echo "www.google.com:443")
}

# ============================================================================
# TASK-7.2: QR Code Generation (PNG)
# ============================================================================

generate_qr_png() {
    local username="$1"
    local uri="$2"
    local output_dir="${CLIENTS_DIR}/${username}"

    # Check if qrencode is available
    if ! command -v qrencode &>/dev/null; then
        log_error "qrencode is not installed. Install with: apt-get install qrencode"
        return 1
    fi

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    # Generate PNG QR code (400x400 pixels)
    # -s 10: Module size 10 pixels (40 modules * 10 = 400px)
    # -t PNG: Output format
    # -o: Output file
    local qr_file="${output_dir}/qrcode.png"

    if qrencode -t "$QR_PNG_TYPE" -s "$QR_PNG_SIZE" -o "$qr_file" <<< "$uri" 2>/dev/null; then
        chmod 600 "$qr_file"
        log_success "QR code PNG saved: $qr_file (400x400px)"
        return 0
    else
        log_error "Failed to generate PNG QR code"
        return 1
    fi
}

# ============================================================================
# TASK-7.2: QR Code Display (ANSI Terminal)
# ============================================================================

display_qr_ansi() {
    local uri="$1"
    local username="${2:-}"

    # Check if qrencode is available
    if ! command -v qrencode &>/dev/null; then
        log_warning "qrencode is not installed, skipping terminal QR code display"
        return 0
    fi

    echo ""
    if [[ -n "$username" ]]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  QR Code for: $username${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  QR Code${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    echo ""

    # Display ANSI QR code in terminal
    if qrencode -t "$QR_ANSI_TYPE" <<< "$uri" 2>/dev/null; then
        echo ""
        log_success "Scan this QR code with your VPN client app"
    else
        log_error "Failed to generate ANSI QR code"
        return 1
    fi

    echo ""
    return 0
}

# ============================================================================
# TASK-7.3: Connection Info Display
# ============================================================================

display_connection_info() {
    local username="$1"
    local uuid="$2"
    local uri="$3"

    # Get server information
    declare -A server_info
    get_server_info server_info

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Connection Information${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BLUE}Username:${NC}       $username"
    echo -e "  ${BLUE}UUID:${NC}           $uuid"
    echo ""
    echo -e "  ${BLUE}Server:${NC}         ${server_info[server_ip]}:${server_info[server_port]}"
    echo -e "  ${BLUE}Protocol:${NC}       VLESS + Reality"
    echo -e "  ${BLUE}Flow:${NC}           xtls-rprx-vision"
    echo -e "  ${BLUE}Security:${NC}       reality"
    echo ""
    echo -e "  ${BLUE}SNI:${NC}            ${server_info[server_name]}"
    echo -e "  ${BLUE}Fingerprint:${NC}   chrome"
    echo -e "  ${BLUE}Public Key:${NC}    ${server_info[public_key]:0:20}...${server_info[public_key]: -10}"
    echo -e "  ${BLUE}Short ID:${NC}      ${server_info[short_id]}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${MAGENTA}VLESS URI:${NC}"
    echo "$uri"
    echo ""
}

# ============================================================================
# TASK-7.4: Export Connection Config to Files
# ============================================================================

export_connection_config() {
    local username="$1"
    local uuid="$2"
    local uri="$3"
    local output_dir="${CLIENTS_DIR}/${username}"

    # Create output directory
    mkdir -p "$output_dir"
    chmod 700 "$output_dir"

    # 1. Save VLESS URI
    local uri_file="${output_dir}/vless_uri.txt"
    echo "$uri" > "$uri_file"
    chmod 600 "$uri_file"
    log_success "VLESS URI saved: $uri_file"

    # 2. Save connection info (human-readable)
    local info_file="${output_dir}/connection_info.txt"
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  VLESS Reality VPN - Connection Information"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Username:   $username"
        echo "UUID:       $uuid"
        echo "Created:    $(date -Iseconds)"
        echo ""

        # Get server info
        declare -A server_info
        get_server_info server_info

        echo "Server:     ${server_info[server_ip]}:${server_info[server_port]}"
        echo "Protocol:   VLESS + Reality"
        echo "Flow:       xtls-rprx-vision"
        echo "Security:   reality"
        echo ""
        echo "SNI:        ${server_info[server_name]}"
        echo "Fingerprint: chrome"
        echo "Public Key: ${server_info[public_key]}"
        echo "Short ID:   ${server_info[short_id]}"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Connection String (VLESS URI)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "$uri"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Setup Instructions"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "1. Install a VLESS-compatible VPN client:"
        echo "   - Windows: v2rayN"
        echo "   - Android: v2rayNG"
        echo "   - iOS: Shadowrocket"
        echo "   - macOS: V2Box"
        echo "   - Linux: Qv2ray"
        echo ""
        echo "2. Import configuration:"
        echo "   Option A: Scan the QR code (qrcode.png)"
        echo "   Option B: Copy and paste the VLESS URI above"
        echo ""
        echo "3. Connect to the VPN"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } > "$info_file"
    chmod 600 "$info_file"
    log_success "Connection info saved: $info_file"

    # 3. Save JSON config (machine-readable)
    local json_file="${output_dir}/config.json"
    declare -A server_info
    get_server_info server_info

    jq -n \
        --arg username "$username" \
        --arg uuid "$uuid" \
        --arg created "$(date -Iseconds)" \
        --arg server_ip "${server_info[server_ip]}" \
        --arg server_port "${server_info[server_port]}" \
        --arg public_key "${server_info[public_key]}" \
        --arg short_id "${server_info[short_id]}" \
        --arg server_name "${server_info[server_name]}" \
        --arg uri "$uri" \
        '{
            username: $username,
            uuid: $uuid,
            created: $created,
            server: {
                ip: $server_ip,
                port: ($server_port | tonumber),
                protocol: "vless",
                security: "reality"
            },
            reality: {
                sni: $server_name,
                publicKey: $public_key,
                shortId: $short_id,
                fingerprint: "chrome",
                flow: "xtls-rprx-vision"
            },
            uri: $uri
        }' > "$json_file"
    chmod 600 "$json_file"
    log_success "JSON config saved: $json_file"

    return 0
}

# ============================================================================
# TASK-7.1, 7.2, 7.3, 7.4: Main QR Code Generation Function
# ============================================================================

generate_qr_code() {
    local username="$1"
    local uuid="$2"
    local uri="$3"

    log_info "Generating QR code and connection info for user: $username"
    echo ""

    # Validate URI
    if ! validate_vless_uri "$uri"; then
        log_error "Invalid VLESS URI provided"
        return 1
    fi

    # Generate PNG QR code (400x400px)
    if ! generate_qr_png "$username" "$uri"; then
        log_warning "Failed to generate PNG QR code"
    fi

    # Export connection configs to files
    if ! export_connection_config "$username" "$uuid" "$uri"; then
        log_error "Failed to export connection configuration"
        return 1
    fi

    # Display QR code in terminal (ANSI)
    display_qr_ansi "$uri" "$username"

    # Display connection information
    display_connection_info "$username" "$uuid" "$uri"

    # Summary
    local output_dir="${CLIENTS_DIR}/${username}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Files Generated${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  📁 Directory:          $output_dir"
    echo "  🖼️  QR Code (PNG):      qrcode.png (400x400px)"
    echo "  📄 VLESS URI:          vless_uri.txt"
    echo "  📝 Connection Info:    connection_info.txt"
    echo "  🔧 JSON Config:        config.json"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    log_success "QR code and connection info generated successfully!"
    echo ""

    return 0
}

# ============================================================================
# Display QR Code for Existing User
# ============================================================================

show_qr_code() {
    local username="$1"
    local user_dir="${CLIENTS_DIR}/${username}"

    # Check if user directory exists
    if [[ ! -d "$user_dir" ]]; then
        log_error "User '$username' not found"
        return 1
    fi

    # Check if URI file exists
    local uri_file="${user_dir}/vless_uri.txt"
    if [[ ! -f "$uri_file" ]]; then
        log_error "VLESS URI file not found: $uri_file"
        return 1
    fi

    # Read URI
    local uri
    uri=$(cat "$uri_file")

    # Display QR code
    display_qr_ansi "$uri" "$username"

    # Display URI
    echo ""
    echo -e "${MAGENTA}VLESS URI:${NC}"
    echo "$uri"
    echo ""

    # Show file locations
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  Configuration files: $user_dir"
    if [[ -f "${user_dir}/qrcode.png" ]]; then
        echo "  QR Code PNG: ${user_dir}/qrcode.png"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    return 0
}

# ============================================================================
# Export Functions
# ============================================================================

# Export all functions for use by other scripts
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced
    export -f generate_qr_code
    export -f generate_qr_png
    export -f display_qr_ansi
    export -f display_connection_info
    export -f export_connection_config
    export -f validate_vless_uri
    export -f get_server_info
    export -f show_qr_code
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
    case "${1:-}" in
        generate|create)
            if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]] || [[ -z "${4:-}" ]]; then
                log_error "Usage: $0 generate <username> <uuid> <vless_uri>"
                exit 1
            fi
            generate_qr_code "$2" "$3" "$4"
            ;;
        show|display)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 show <username>"
                exit 1
            fi
            show_qr_code "$2"
            ;;
        *)
            echo "Usage: $0 {generate|show} [arguments]"
            echo ""
            echo "Commands:"
            echo "  generate <username> <uuid> <uri>  - Generate QR code and configs"
            echo "  show <username>                    - Display QR code for existing user"
            echo ""
            exit 1
            ;;
    esac
fi
