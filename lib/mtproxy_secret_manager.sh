#!/bin/bash
# ============================================================================
# VLESS Reality Deployment System
# Module: MTProxy Secret Manager
# Version: 6.1.0
# ============================================================================
#
# Purpose:
#   MTProxy secret generation, validation, and management system.
#   Supports 3 secret types: standard (32 hex), dd (34 hex, random padding),
#   ee (32 hex key + variable hex domain encoding for fake-TLS).
#
# Functions:
#   1. generate_mtproxy_secret()        - Generate random secret (type: standard/dd/ee)
#   2. validate_mtproxy_secret()        - Validate secret format
#   3. add_secret_to_db()               - Add secret to secrets.json (atomic)
#   4. remove_secret_from_db()          - Remove secret from secrets.json (atomic)
#   5. list_secrets()                   - List all secrets from DB
#   6. secret_exists()                  - Check if secret exists in DB
#   7. get_secret_info()                - Get secret details by ID
#   8. encode_domain_to_hex()           - Encode domain for ee-type secrets (v6.1)
#   9. regenerate_proxy_secret_file()   - Regenerate proxy-secret from DB
#
# Usage:
#   source lib/mtproxy_secret_manager.sh
#   generate_mtproxy_secret "standard"
#   generate_mtproxy_secret "dd"
#   generate_mtproxy_secret "ee" "www.google.com"
#
# Dependencies:
#   - openssl or /dev/urandom (random generation)
#   - jq (JSON processing)
#   - flock (atomic operations)
#
# Author: VLESS Development Team
# Date: 2025-11-08
# ============================================================================

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

# Installation paths (only define if not already set)
[[ -z "${VLESS_HOME:-}" ]] && readonly VLESS_HOME="/opt/familytraffic"
[[ -z "${MTPROXY_CONFIG_DIR:-}" ]] && readonly MTPROXY_CONFIG_DIR="${VLESS_HOME}/config/mtproxy"
[[ -z "${MTPROXY_SECRETS_JSON:-}" ]] && readonly MTPROXY_SECRETS_JSON="${MTPROXY_CONFIG_DIR}/secrets.json"
[[ -z "${MTPROXY_SECRET_FILE:-}" ]] && readonly MTPROXY_SECRET_FILE="${MTPROXY_CONFIG_DIR}/proxy-secret"
[[ -z "${LOCK_FILE:-}" ]] && readonly LOCK_FILE="/var/lock/mtproxy_secrets.lock"

# Colors for output (only define if not already set)
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================

secret_log_info() {
    echo -e "${BLUE}[Secret Manager INFO]${NC} $*"
}

secret_log_success() {
    echo -e "${GREEN}[Secret Manager ✓]${NC} $*"
}

secret_log_warning() {
    echo -e "${YELLOW}[Secret Manager ⚠]${NC} $*"
}

secret_log_error() {
    echo -e "${RED}[Secret Manager ✗]${NC} $*" >&2
}

# ============================================================================
# FUNCTION: generate_mtproxy_secret
# ============================================================================
# Description: Generate MTProxy secret (3 types supported)
#
# Parameters:
#   $1 - type: "standard" (32 hex), "dd" (34 hex), "ee" (34 hex + full domain hex)
#   $2 - domain (required for type="ee", e.g., "www.google.com")
#
# Returns:
#   Secret string to stdout, 1 on error
#
# Examples:
#   generate_mtproxy_secret "standard"                # Returns: 32 hex chars
#   generate_mtproxy_secret "dd"                      # Returns: "dd" + 32 hex chars
#   generate_mtproxy_secret "ee" "www.google.com"     # Returns: "ee" + 32 hex + hex(domain)
#
# Secret formats (MTProxy specification):
#   - standard: 32 hex characters (16 bytes)
#   - dd: "dd" + 32 hex characters (random padding enabled)
#   - ee: "ee" + 32 hex + full domain UTF-8 hex (fake-TLS)
# ============================================================================
generate_mtproxy_secret() {
    local secret_type="${1:-standard}"
    local domain="${2:-}"

    # Validate secret type
    if [[ ! "$secret_type" =~ ^(standard|dd|ee)$ ]]; then
        secret_log_error "Invalid secret type: ${secret_type} (must be: standard, dd, or ee)"
        return 1
    fi

    # For ee type, domain is required
    if [[ "$secret_type" == "ee" ]] && [[ -z "$domain" ]]; then
        secret_log_error "Domain required for ee-type secret (fake-TLS)"
        return 1
    fi

    # Generate 16 random bytes (32 hex characters)
    local random_hex
    if command -v openssl &>/dev/null; then
        random_hex=$(openssl rand -hex 16)
    elif [[ -r /dev/urandom ]]; then
        random_hex=$(head -c 16 /dev/urandom | xxd -p -c 16)
    else
        secret_log_error "Cannot generate random bytes (no openssl or /dev/urandom)"
        return 1
    fi

    # Build secret based on type
    local secret=""
    case "$secret_type" in
        standard)
            # Standard secret: just 32 hex chars
            secret="${random_hex}"
            ;;

        dd)
            # dd-type: "dd" + 32 hex (random padding enabled)
            secret="dd${random_hex}"
            ;;

        ee)
            # ee-type: "ee" + 32 hex + 16 hex domain encoding (fake-TLS)
            local domain_hex
            if ! domain_hex=$(encode_domain_to_hex "$domain"); then
                secret_log_error "Failed to encode domain: ${domain}"
                return 1
            fi

            secret="ee${random_hex}${domain_hex}"
            ;;

        *)
            secret_log_error "Unknown secret type: ${secret_type}"
            return 1
            ;;
    esac

    # Output secret to stdout
    echo "$secret"
    return 0
}

# ============================================================================
# FUNCTION: encode_domain_to_hex
# ============================================================================
# Description: Encode full domain name to hex for ee-type secrets
#
# Parameters:
#   $1 - domain (e.g., "www.google.com")
#
# Returns:
#   Variable-length hex string (full domain UTF-8 encoded), 1 on error
#
# Example:
#   encode_domain_to_hex "www.google.com"  # Returns: hex of full domain
#
# Note:
#   MTProxy ee-type secret format: "ee" + 32hex(16 random bytes) + hex(domain)
#   The domain is the full hostname encoded as UTF-8 hex — no truncation.
# ============================================================================
encode_domain_to_hex() {
    local domain="$1"

    # Validate domain
    if [[ -z "$domain" ]]; then
        secret_log_error "Domain cannot be empty"
        return 1
    fi

    # Convert full domain to hex (no truncation)
    local domain_hex
    if command -v xxd &>/dev/null; then
        domain_hex=$(echo -n "$domain" | xxd -p | tr -d '\n')
    elif command -v hexdump &>/dev/null; then
        domain_hex=$(echo -n "$domain" | hexdump -v -e '/1 "%02x"')
    else
        secret_log_error "Cannot encode domain (no xxd or hexdump)"
        return 1
    fi

    echo "$domain_hex"
    return 0
}

# ============================================================================
# FUNCTION: validate_mtproxy_secret
# ============================================================================
# Description: Validate MTProxy secret format
#
# Parameters:
#   $1 - secret string
#
# Returns:
#   0 if valid, 1 if invalid
#
# Examples:
#   validate_mtproxy_secret "abcd1234..."  # standard (32 hex)
#   validate_mtproxy_secret "ddabcd1234..."  # dd-type (34 hex)
#   validate_mtproxy_secret "eeabcd1234...domain_hex"  # ee-type (variable length)
# ============================================================================
validate_mtproxy_secret() {
    local secret="$1"

    # Check if secret is empty
    if [[ -z "$secret" ]]; then
        secret_log_error "Secret cannot be empty"
        return 1
    fi

    # Detect secret type and validate format
    if [[ "$secret" =~ ^dd[0-9a-fA-F]{32}$ ]]; then
        # dd-type: "dd" + 32 hex (total 34 chars)
        return 0

    elif [[ "$secret" =~ ^ee[0-9a-fA-F]{34,}$ ]]; then
        # ee-type: "ee" + 32 hex (key) + variable hex (full domain UTF-8 encoded)
        return 0

    elif [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
        # standard: 32 hex chars
        return 0

    else
        secret_log_error "Invalid secret format: ${secret}"
        secret_log_error "Expected formats:"
        secret_log_error "  - standard: 32 hex characters"
        secret_log_error "  - dd-type:  'dd' + 32 hex characters (34 total)"
        secret_log_error "  - ee-type:  'ee' + 32 hex (key) + domain hex (variable length)"
        return 1
    fi
}

# ============================================================================
# FUNCTION: add_secret_to_db
# ============================================================================
# Description: Add secret to secrets.json (atomic operation with flock)
#
# Parameters:
#   $1 - secret string
#   $2 - type ("standard", "dd", "ee")
#   $3 - username (optional, for v6.1 multi-user)
#   $4 - domain (optional, for ee-type secrets)
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   add_secret_to_db "abcd1234..." "standard"
#   add_secret_to_db "ddabcd..." "dd" "alice"
#   add_secret_to_db "eeabcd..." "ee" "bob" "www.google.com"
# ============================================================================
add_secret_to_db() {
    local secret="$1"
    local secret_type="${2:-standard}"
    local username="${3:-}"
    local domain="${4:-}"

    # Validate secret
    if ! validate_mtproxy_secret "$secret"; then
        secret_log_error "Invalid secret format"
        return 1
    fi

    # Ensure secrets.json exists
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        secret_log_error "Secrets DB not found: ${MTPROXY_SECRETS_JSON}"
        secret_log_error "Run 'mtproxy_init' first"
        return 1
    fi

    # Use flock for atomic operation
    (
        flock -x 200 || {
            secret_log_error "Failed to acquire lock on ${MTPROXY_SECRETS_JSON}"
            return 1
        }

        # Check if secret already exists (prevent duplicates)
        if jq -e ".secrets[] | select(.secret == \"${secret}\")" "${MTPROXY_SECRETS_JSON}" &>/dev/null; then
            secret_log_error "Secret already exists in database"
            return 1
        fi

        # Create new secret entry
        local created_at
        created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        local new_entry
        new_entry=$(jq -n \
            --arg secret "$secret" \
            --arg type "$secret_type" \
            --arg username "$username" \
            --arg domain "$domain" \
            --arg created_at "$created_at" \
            '{
                secret: $secret,
                type: $type,
                username: $username,
                domain: $domain,
                created_at: $created_at
            }')

        # Add to secrets array
        jq ".secrets += [$new_entry] | .metadata.last_modified = \"${created_at}\"" \
            "${MTPROXY_SECRETS_JSON}" > "${MTPROXY_SECRETS_JSON}.tmp"

        # Atomic replace
        mv "${MTPROXY_SECRETS_JSON}.tmp" "${MTPROXY_SECRETS_JSON}"
        chmod 600 "${MTPROXY_SECRETS_JSON}"  # preserve 0600 after atomic mv (tmp inherits umask)

        secret_log_success "Secret added to database"
        secret_log_info "  Type: ${secret_type}"
        if [[ -n "$username" ]]; then
            secret_log_info "  User: ${username}"
        fi
        if [[ -n "$domain" ]]; then
            secret_log_info "  Domain: ${domain}"
        fi

    ) 200>"${LOCK_FILE}"

    return 0
}

# ============================================================================
# FUNCTION: remove_secret_from_db
# ============================================================================
# Description: Remove secret from secrets.json (atomic operation)
#
# Parameters:
#   $1 - secret string or username
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   remove_secret_from_db "abcd1234..."
#   remove_secret_from_db "alice"  # remove by username
# ============================================================================
remove_secret_from_db() {
    local identifier="$1"

    # Ensure secrets.json exists
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        secret_log_error "Secrets DB not found: ${MTPROXY_SECRETS_JSON}"
        return 1
    fi

    # Use flock for atomic operation
    (
        flock -x 200 || {
            secret_log_error "Failed to acquire lock on ${MTPROXY_SECRETS_JSON}"
            return 1
        }

        # Check if secret exists (by secret or username)
        local count
        count=$(jq "[.secrets[] | select(.secret == \"${identifier}\" or .username == \"${identifier}\")] | length" "${MTPROXY_SECRETS_JSON}")

        if [[ "$count" -eq 0 ]]; then
            secret_log_error "Secret not found: ${identifier}"
            return 1
        fi

        # Remove secret
        local updated_at
        updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        jq ".secrets = [.secrets[] | select(.secret != \"${identifier}\" and .username != \"${identifier}\")] | .metadata.last_modified = \"${updated_at}\"" \
            "${MTPROXY_SECRETS_JSON}" > "${MTPROXY_SECRETS_JSON}.tmp"

        # Atomic replace
        mv "${MTPROXY_SECRETS_JSON}.tmp" "${MTPROXY_SECRETS_JSON}"
        chmod 600 "${MTPROXY_SECRETS_JSON}"  # preserve 0600 after atomic mv (tmp inherits umask)

        secret_log_success "Secret removed from database"

    ) 200>"${LOCK_FILE}"

    return 0
}

# ============================================================================
# FUNCTION: list_secrets
# ============================================================================
# Description: List all secrets from secrets.json
#
# Parameters:
#   None
#
# Returns:
#   0 on success, prints secrets to stdout
#
# Example:
#   list_secrets
# ============================================================================
list_secrets() {
    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        secret_log_error "Secrets DB not found: ${MTPROXY_SECRETS_JSON}"
        return 1
    fi

    local count
    count=$(jq -r '.secrets | length' "${MTPROXY_SECRETS_JSON}")

    if [[ "$count" -eq 0 ]]; then
        secret_log_warning "No secrets found"
        return 0
    fi

    # Resolve server IP once for all deep links
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null || echo "")
    local port="${MTPROXY_PORT:-2053}"

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              MTProxy Secrets Database                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local i secret secret_type username domain created_at deeplink
    for (( i=0; i<count; i++ )); do
        secret=$(jq -r ".secrets[${i}].secret"      "${MTPROXY_SECRETS_JSON}")
        secret_type=$(jq -r ".secrets[${i}].type"   "${MTPROXY_SECRETS_JSON}")
        username=$(jq -r ".secrets[${i}].username // \"\"" "${MTPROXY_SECRETS_JSON}")
        domain=$(jq -r ".secrets[${i}].domain // \"\""     "${MTPROXY_SECRETS_JSON}")
        created_at=$(jq -r ".secrets[${i}].created_at"     "${MTPROXY_SECRETS_JSON}")

        echo -e "${BLUE}#$((i+1))${NC}"
        echo -e "  Type:    ${secret_type}"
        echo -e "  Secret:  ${secret}"
        [[ -n "$username" ]] && echo -e "  User:    ${username}"
        [[ -n "$domain"   ]] && echo -e "  Domain:  ${domain} (fake-TLS)"
        echo -e "  Created: ${created_at}"

        if [[ -n "$server_ip" ]]; then
            deeplink="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"
            echo -e "  ${YELLOW}Link:${NC}    ${deeplink}"
        fi
        echo ""
    done

    echo -e "${BLUE}Total: ${count} secret(s)${NC}"
    return 0
}

# ============================================================================
# FUNCTION: secret_exists
# ============================================================================
# Description: Check if secret exists in database
#
# Parameters:
#   $1 - secret string or username
#
# Returns:
#   0 if exists, 1 if not
#
# Example:
#   if secret_exists "alice"; then echo "Exists"; fi
# ============================================================================
secret_exists() {
    local identifier="$1"

    if [[ ! -f "${MTPROXY_SECRETS_JSON}" ]]; then
        return 1
    fi

    jq -e ".secrets[] | select(.secret == \"${identifier}\" or .username == \"${identifier}\")" "${MTPROXY_SECRETS_JSON}" &>/dev/null
}

# ============================================================================
# FUNCTION: regenerate_proxy_secret_file
# ============================================================================
# Description: Regenerate proxy-secret file from secrets.json
#              (wrapper around mtproxy_manager.sh::generate_mtproxy_secret_file)
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   regenerate_proxy_secret_file
# ============================================================================
regenerate_proxy_secret_file() {
    # Source mtproxy_manager.sh if not already loaded
    if ! declare -f generate_mtproxy_secret_file &>/dev/null; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

        if [[ -f "${script_dir}/mtproxy_manager.sh" ]]; then
            # shellcheck source=./mtproxy_manager.sh
            source "${script_dir}/mtproxy_manager.sh"
        else
            secret_log_error "mtproxy_manager.sh not found"
            return 1
        fi
    fi

    # Call mtproxy_manager function
    generate_mtproxy_secret_file
}

# ============================================================================
# FUNCTION: validate_mtproxy_domain (v6.1)
# ============================================================================
# Description: Validate domain for ee-type (fake-TLS) MTProxy secrets
#
# Parameters:
#   $1 - domain (string, e.g., "www.google.com")
#   $2 - dns_check (optional, "true"|"false", default: "false")
#
# Returns:
#   0 if valid, 1 if invalid
#
# Examples:
#   validate_mtproxy_domain "www.google.com"           # Basic validation
#   validate_mtproxy_domain "www.google.com" "true"    # With DNS check
#
# Notes:
#   - MTProxy fake-TLS требует реально существующий домен
#   - Домен должен быть популярным сайтом (не блокируется в регионе)
#   - Рекомендуемые домены: www.google.com, www.cloudflare.com, www.bing.com
# ============================================================================
validate_mtproxy_domain() {
    local domain="$1"
    local dns_check="${2:-false}"

    # Validate domain format (basic regex)
    if [[ -z "$domain" ]]; then
        secret_log_error "Domain cannot be empty"
        return 1
    fi

    # Check length (max 253 chars for FQDN)
    if [[ ${#domain} -gt 253 ]]; then
        secret_log_error "Domain too long (max 253 characters)"
        return 1
    fi

    # Regex validation: alphanumeric with dots and hyphens
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        secret_log_error "Invalid domain format: $domain"
        secret_log_error "Valid format: alphanumeric with dots and hyphens (e.g., www.google.com)"
        return 1
    fi

    # Check for localhost/reserved domains
    if [[ "$domain" =~ ^(localhost|127\.|10\.|172\.|192\.168\.) ]]; then
        secret_log_error "Domain cannot be localhost or private IP"
        return 1
    fi

    # Optional DNS check
    if [[ "$dns_check" == "true" ]]; then
        secret_log_info "Performing DNS check for: $domain"

        # Try nslookup first
        if command -v nslookup &>/dev/null; then
            if ! nslookup "$domain" &>/dev/null; then
                secret_log_warning "DNS resolution failed for: $domain"
                secret_log_warning "Domain may not exist or DNS is unreachable"
                secret_log_warning "MTProxy ee-type requires real, resolvable domain"
                return 1
            fi
        # Fallback to host command
        elif command -v host &>/dev/null; then
            if ! host "$domain" &>/dev/null; then
                secret_log_warning "DNS resolution failed for: $domain"
                secret_log_warning "Domain may not exist or DNS is unreachable"
                return 1
            fi
        else
            secret_log_warning "DNS check requested but no nslookup/host command available"
            secret_log_warning "Skipping DNS validation (domain format check passed)"
        fi

        secret_log_success "DNS check passed: $domain"
    fi

    return 0
}

# ============================================================================
# Module Initialization Complete
# ============================================================================

secret_log_info "MTProxy Secret Manager module loaded (v6.1)"
