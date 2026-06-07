#!/bin/bash
#
# Installation Orchestrator Module
# Part of VLESS+Reality VPN Deployment System
#
# Purpose: Orchestrate the complete installation process by creating directory
#          structure, generating configurations, setting up networking, and
#          deploying Docker containers.
# Usage: source this file from install.sh
#
# TASK-1.7: Installation orchestration (5h)
#
# This module uses parameters collected by interactive_params.sh:
#   - REALITY_DEST
#   - REALITY_DEST_PORT
#   - VLESS_PORT
#   - DOCKER_SUBNET
#

set -euo pipefail

# =============================================================================
# IMPORT MODULES
# =============================================================================
# Source Nginx and docker-compose generators
# v5.30: nginx_stream_generator.sh (stream+http) replaced haproxy_config_manager.sh
SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR_LIB}/nginx_stream_generator.sh" ]] && source "${SCRIPT_DIR_LIB}/nginx_stream_generator.sh"

# =============================================================================
# IMPORT v5.23 MODULES (External Proxy Support)
# =============================================================================
# Source external proxy and routing managers (v5.23 external proxy feature)
# These modules enable routing traffic through upstream SOCKS5/HTTP proxies
[[ -f "${SCRIPT_DIR_LIB}/external_proxy_manager.sh" ]] && source "${SCRIPT_DIR_LIB}/external_proxy_manager.sh"
[[ -f "${SCRIPT_DIR_LIB}/xray_routing_manager.sh" ]] && source "${SCRIPT_DIR_LIB}/xray_routing_manager.sh"

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Color codes for output
# Only define if not already set (to avoid conflicts when sourced after install.sh)
[[ -z "${RED:-}" ]] && RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && NC='\033[0m' # No Color

# Installation paths
readonly INSTALL_ROOT="/opt/familytraffic"
readonly VLESS_DIR="${INSTALL_ROOT}"
readonly CONFIG_DIR="${INSTALL_ROOT}/config"
readonly DATA_DIR="${INSTALL_ROOT}/data"
readonly LOGS_DIR="${INSTALL_ROOT}/logs"
readonly KEYS_DIR="${INSTALL_ROOT}/keys"
readonly SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
readonly FAKESITE_DIR="${INSTALL_ROOT}/fake-site"
readonly DOCS_DIR="${INSTALL_ROOT}/docs"
readonly TESTS_DIR="${INSTALL_ROOT}/tests"

# Docker configuration
readonly DOCKER_NETWORK_NAME="familytraffic_reality_net"
readonly XRAY_IMAGE="teddysun/xray:24.11.30"
readonly NGINX_IMAGE="nginx:alpine"
readonly XRAY_CONTAINER_NAME="familytraffic"
readonly NGINX_MAIN_CONTAINER_NAME="familytraffic"         # v5.33: single container (nginx+xray+certbot)

# familyTraffic container image (v5.33 single-container)
# INFO-3 fix: warn on literal OWNER placeholder instead of silently writing wrong value to .env
if [[ -z "${GHCR_IMAGE:-}" ]]; then
    if [[ -n "$(git -C "${INSTALL_ROOT}" config --get remote.origin.url 2>/dev/null)" ]]; then
        _git_owner=$(git -C "${INSTALL_ROOT}" config --get remote.origin.url \
            | sed 's|.*github.com[:/]\([^/]*\)/.*|\1|' 2>/dev/null || true)
        [[ -n "${_git_owner}" ]] && GHCR_IMAGE="ghcr.io/${_git_owner}/familytraffic" \
            || GHCR_IMAGE="ghcr.io/OWNER/familytraffic"
    else
        GHCR_IMAGE="ghcr.io/OWNER/familytraffic"
        echo "[WARN] GHCR_IMAGE not set and git remote not found. Set GHCR_IMAGE env var before install." >&2
    fi
fi
[[ -z "${FT_IMAGE_TAG:-}" ]] && FT_IMAGE_TAG="latest"

# Configuration files (conditional to avoid conflicts when sourced by CLI)
[[ -z "${XRAY_CONFIG:-}" ]] && readonly XRAY_CONFIG="${CONFIG_DIR}/xray_config.json"
[[ -z "${USERS_JSON:-}" ]] && readonly USERS_JSON="${DATA_DIR}/users.json"
readonly DOCKER_COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
readonly NGINX_CONFIG="${CONFIG_DIR}/nginx/nginx.conf"
[[ -z "${ENV_FILE:-}" ]] && readonly ENV_FILE="${INSTALL_ROOT}/.env"

# UFW configuration
readonly UFW_AFTER_RULES="/etc/ufw/after.rules"
readonly UFW_BACKUP_DIR="/tmp/ufw_backup_$(date +%Y%m%d_%H%M%S)"

# Generated keys and IDs (will be set during execution)
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

# =============================================================================
# FUNCTION: orchestrate_installation
# =============================================================================
# Description: Main orchestration function that coordinates all installation steps
# Called by: install.sh main() at Step 8
# Returns: 0 on success, 1 on failure
# =============================================================================
orchestrate_installation() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           INSTALLATION ORCHESTRATION                         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Step 1: Create directory structure
    create_directory_structure || {
        echo -e "${RED}Failed to create directory structure${NC}" >&2
        return 1
    }

    # Step 1.5: Set initial permissions (CRITICAL: before container deployment)
    # Set ownership for log directories so containers can write logs
    echo -e "${CYAN}[1.5/12] Setting initial permissions for log directories...${NC}"
    if [[ -d "${LOGS_DIR}/xray" ]]; then
        chown -R root:root "${LOGS_DIR}/xray" || {
            echo -e "${RED}Failed to set xray logs ownership${NC}" >&2
            return 1
        }
        chmod 755 "${LOGS_DIR}/xray"
    fi
    if [[ -d "${LOGS_DIR}/nginx" ]]; then
        chown -R 101:101 "${LOGS_DIR}/nginx" || {
            echo -e "${RED}Failed to set nginx logs ownership${NC}" >&2
            return 1
        }
        chmod 755 "${LOGS_DIR}/nginx"
    fi
    if [[ -d "${LOGS_DIR}/fake-site" ]]; then
        chown -R 101:101 "${LOGS_DIR}/fake-site" || {
            echo -e "${RED}Failed to set fake-site logs ownership${NC}" >&2
            return 1
        }
        chmod 755 "${LOGS_DIR}/fake-site"
    fi

    # Set permissions on Let's Encrypt live directory for container access
    # familytraffic_nginx (nginx:1.27-alpine) needs rx to traverse path
    if [[ -d "/etc/letsencrypt/live" ]]; then
        chmod 755 /etc/letsencrypt/live || {
            echo -e "${YELLOW}Warning: Failed to set permissions on /etc/letsencrypt/live${NC}" >&2
            # Non-critical: Continue installation (certificates may not be configured yet)
        }
    fi

    echo "  ✓ Log directory permissions set"

    # Step 2: Generate X25519 keys
    generate_reality_keys || {
        echo -e "${RED}Failed to generate Reality keys${NC}" >&2
        return 1
    }

    # Step 3: Generate Short ID
    generate_short_id || {
        echo -e "${RED}Failed to generate Short ID${NC}" >&2
        return 1
    }

    # Step 4: Create Xray configuration (with optional proxy support)
    # v3.2: Use ENABLE_PUBLIC_PROXY to determine if proxy inbounds should be created
    create_xray_config "${ENABLE_PUBLIC_PROXY:-false}" || {
        echo -e "${RED}Failed to create Xray configuration${NC}" >&2
        return 1
    }

    # Step 5: Create empty users.json
    create_users_json || {
        echo -e "${RED}Failed to create users.json${NC}" >&2
        return 1
    }

    # Step 5.5: Initialize proxy_allowed_ips.json (v3.6 - server-level IP whitelist)
    init_proxy_allowed_ips || {
        echo -e "${RED}Failed to initialize proxy IP whitelist${NC}" >&2
        return 1
    }

    # Step 5.6: Initialize external_proxy.json (v5.23 - external proxy support)
    # Create empty database for external proxy configuration
    # Users can add proxies later via familytraffic-external-proxy CLI
    if declare -f init_external_proxy_db >/dev/null 2>&1; then
        init_external_proxy_db || {
            echo -e "${YELLOW}Warning: Failed to initialize external proxy database${NC}"
            echo -e "${YELLOW}External proxy feature will not be available${NC}"
        }
    else
        echo -e "${YELLOW}Note: External proxy manager not loaded, skipping database initialization${NC}"
    fi

    # Step 6: Create Nginx configuration
    create_nginx_config || {
        echo -e "${RED}Failed to create Nginx configuration${NC}" >&2
        return 1
    }


    # Step 6.5: Generate Nginx configuration (v5.30 unified stream+http, replaces HAProxy)
    generate_nginx_config_wrapper || {
        echo -e "${RED}Failed to generate Nginx configuration${NC}" >&2
        return 1
    }

    # Step 7: Create docker-compose.yml
    create_docker_compose || {
        echo -e "${RED}Failed to create docker-compose.yml${NC}" >&2
        return 1
    }

    # Step 8: Create .env file
    create_env_file || {
        echo -e "${RED}Failed to create .env file${NC}" >&2
        return 1
    }

    # Step 9: Docker network — SKIPPED (v5.33: single container uses network_mode: host)
    echo -e "${CYAN}[9/12] Docker network: skipped (single container, network_mode: host)${NC}"

    # Step 9.5: Setup fail2ban (v3.3 - for all proxy modes: localhost + public)
    if [[ "${ENABLE_PROXY:-false}" == "true" ]]; then
        echo ""
        echo -e "${CYAN}[9.5/12] Setting up fail2ban for proxy protection...${NC}"

        # Source fail2ban module
        if [[ -f "${SCRIPT_DIR}/lib/fail2ban_setup.sh" ]]; then
            source "${SCRIPT_DIR}/lib/fail2ban_setup.sh"
        fi

        if ! setup_fail2ban_for_proxy; then
            echo -e "${RED}Failed to setup fail2ban${NC}" >&2
            echo -e "${YELLOW}WARNING: Proxy will be less secure without fail2ban protection${NC}"
            echo -e "${YELLOW}Continue installation? [y/N]: ${NC}" >&2
            read -r response
            if [[ "${response,,}" != "y" && "${response,,}" != "yes" ]]; then
                return 1
            fi
        fi
    fi

    # Step 10: Configure UFW firewall
    configure_ufw || {
        echo -e "${RED}Failed to configure UFW${NC}" >&2
        return 1
    }

    # Step 10.5: Configure proxy firewall rules (v3.2 - conditional on ENABLE_PUBLIC_PROXY)
    if [[ "${ENABLE_PUBLIC_PROXY:-false}" == "true" ]]; then
        configure_proxy_firewall_rules || {
            echo -e "${RED}Failed to configure proxy firewall rules${NC}" >&2
            return 1
        }
    fi

    # Step 11: Set permissions (MUST run BEFORE deploy_containers!)
    # Docker mounts files with current permissions - changing them after won't affect running containers
    set_permissions || {
        echo -e "${RED}Failed to set permissions${NC}" >&2
        return 1
    }

    # Step 12: Verify critical file permissions (before Docker mounts them)
    verify_file_permissions || {
        echo -e "${RED}Permission verification failed${NC}" >&2
        echo -e "${YELLOW}Cannot proceed with container deployment${NC}" >&2
        echo -e "${YELLOW}Follow manual fixes above to resolve issues${NC}" >&2
        return 1
    }

    # Step 13: Deploy containers (now files have correct permissions)
    deploy_containers || {
        echo -e "${RED}Failed to deploy containers${NC}" >&2
        return 1
    }

    # Step 14: Install CLI tools
    install_cli_tools || {
        echo -e "${RED}Failed to install CLI tools${NC}" >&2
        return 1
    }

    # Step 14.5: Setup logrotate for xray error logs
    setup_xray_logrotate || {
        echo -e "${YELLOW}Warning: Failed to setup logrotate for xray logs${NC}" >&2
        # Non-critical: continue installation
    }

    echo ""
    echo -e "${GREEN}✓ Installation orchestration completed successfully${NC}"
    echo ""

    return 0
}

# =============================================================================
# FUNCTION: create_directory_structure
# =============================================================================
# Description: Create /opt/familytraffic directory structure with proper permissions
# Returns: 0 on success, 1 on failure
# =============================================================================
create_directory_structure() {
    echo -e "${CYAN}[1/12] Creating directory structure...${NC}"

    # Create main installation directory
    if [[ ! -d "${INSTALL_ROOT}" ]]; then
        mkdir -p "${INSTALL_ROOT}" || {
            echo -e "${RED}Failed to create ${INSTALL_ROOT}${NC}" >&2
            return 1
        }
        echo "  ✓ Created ${INSTALL_ROOT}"
    else
        echo "  ✓ ${INSTALL_ROOT} already exists"
    fi

    # Create subdirectories
    local directories=(
        "${CONFIG_DIR}"
        "${CONFIG_DIR}/nginx"
        "${CONFIG_DIR}/supervisord.d"
        "${DATA_DIR}"
        "${DATA_DIR}/clients"
        "${DATA_DIR}/backups"
        "${INSTALL_ROOT}/backup"
        "${INSTALL_ROOT}/lib"
        "${LOGS_DIR}"
        "${LOGS_DIR}/xray"
        "${LOGS_DIR}/nginx"
        "${LOGS_DIR}/fake-site"
        "${KEYS_DIR}"
        "${SCRIPTS_DIR}"
        "${FAKESITE_DIR}"
        "${DOCS_DIR}"
        "${TESTS_DIR}"
        "${TESTS_DIR}/unit"
        "${TESTS_DIR}/integration"
    )


    for dir in "${directories[@]}"; do
        # Always ensure directory exists (mkdir -p is idempotent)
        mkdir -p "$dir" || {
            echo -e "${RED}Failed to create $dir${NC}" >&2
            return 1
        }
        if [[ -d "$dir" ]]; then
            echo "  ✓ $dir exists"
        fi
    done

    echo -e "${GREEN}✓ Directory structure created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: generate_reality_keys
# =============================================================================
# Description: Generate X25519 keypair for Reality protocol
# Sets: PRIVATE_KEY, PUBLIC_KEY
# Returns: 0 on success, 1 on failure
# =============================================================================
generate_reality_keys() {
    echo -e "${CYAN}[2/12] Generating X25519 Reality keys...${NC}"

    # Check if xray command is available (should be from Docker image)
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Docker command not found${NC}" >&2
        return 1
    fi

    # Generate keys using xray Docker image
    local key_output
    key_output=$(docker run --rm "${XRAY_IMAGE}" xray x25519 2>/dev/null)

    if [[ -z "$key_output" ]]; then
        echo -e "${RED}Failed to generate X25519 keys${NC}" >&2
        return 1
    fi

    # Parse private and public keys
    PRIVATE_KEY=$(echo "$key_output" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$key_output" | grep "Public key:" | awk '{print $3}')

    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}Failed to parse keys from xray output${NC}" >&2
        echo "Output was: $key_output" >&2
        return 1
    fi

    # Save keys to files
    echo "$PRIVATE_KEY" > "${KEYS_DIR}/private.key" || return 1
    echo "$PUBLIC_KEY" > "${KEYS_DIR}/public.key" || return 1

    echo "  ✓ Private key: ${PRIVATE_KEY:0:10}...${PRIVATE_KEY: -10}"
    echo "  ✓ Public key: ${PUBLIC_KEY:0:10}...${PUBLIC_KEY: -10}"
    echo "  ✓ Keys saved to ${KEYS_DIR}/"

    echo -e "${GREEN}✓ Reality keys generated${NC}"
    return 0
}

# =============================================================================
# FUNCTION: generate_short_id
# =============================================================================
# Description: Generate Short ID for Reality protocol
# Sets: SHORT_ID
# Returns: 0 on success, 1 on failure
# =============================================================================
generate_short_id() {
    echo -e "${CYAN}[3/12] Generating Short ID...${NC}"

    # Generate 8-byte (16 hex characters) short ID
    SHORT_ID=$(openssl rand -hex 8)

    if [[ -z "$SHORT_ID" ]]; then
        echo -e "${RED}Failed to generate Short ID${NC}" >&2
        return 1
    fi

    echo "  ✓ Short ID: ${SHORT_ID}"

    echo -e "${GREEN}✓ Short ID generated${NC}"
    return 0
}

# =============================================================================
# FUNCTION: generate_routing_json
# =============================================================================
# Description: Generate routing rules for server-level IP whitelisting (v3.6)
# Returns: JSON string for routing section
# Logic:
#   - Read allowed IPs from proxy_allowed_ips.json (server-level)
#   - Allow connections from whitelisted IPs to proxy ports
#   - Block all other connections to proxy ports
# Related: v3.6 Server-Level IP Whitelisting
# Note: NO per-user IP filtering (user field doesn't work for HTTP/SOCKS5)
# =============================================================================
generate_routing_json() {
    local proxy_ips_file="/opt/familytraffic/config/proxy_allowed_ips.json"
    local allowed_ips='["127.0.0.1"]'  # Default: localhost only
    local docker_subnet=""

    # v5.30: familytraffic_nginx (stream block) connects to Xray via Docker network (not localhost)
    # Ports 10800/18118 NOT exposed to host — Docker network provides isolation

    # Check if proxy_allowed_ips.json exists (user-defined overrides)
    if [[ -f "$proxy_ips_file" ]]; then
        # Read allowed IPs from file
        local user_ips=$(jq -c '.allowed_ips' "$proxy_ips_file" 2>/dev/null)

        # Validate JSON and use if valid
        if [[ -n "$user_ips" ]] && [[ "$user_ips" != "null" ]] && echo "$user_ips" | jq empty 2>/dev/null; then
            allowed_ips="$user_ips"
        else
            # Fallback to defaults if file is corrupted (v4.3: localhost only)
            allowed_ips='["127.0.0.1"]'
        fi
    fi

    # Generate routing configuration with server-level IP whitelist
    # v5.30+ Nginx Architecture: Blocking rule removed because:
    #   - Ports 10800/18118 NOT exposed publicly (Nginx terminates TLS on 1080/8118)
    #   - Docker network provides isolation
    #   - familytraffic_nginx connects from Docker network IP (not whitelisted 127.0.0.1)
    #   - Blocking rule would break Nginx → Xray proxy connections
    # Rule 1: Allow whitelisted IPs to access proxy ports (legacy, kept for future use)
    # v5.31: Changed to AsIs for mobile network compatibility
    cat <<EOF
,
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks5-proxy", "http-proxy"],
        "source": ${allowed_ips},
        "outboundTag": "direct"
      }
    ]
  }
EOF
}

# =============================================================================
# FUNCTION: generate_socks5_inbound_json
# =============================================================================
# Description: Generate SOCKS5 proxy inbound configuration for Xray
# Returns: JSON string for SOCKS5 inbound (to be appended to inbounds array)
# Related: TASK-11.1 (SOCKS5 Proxy Inbound Configuration)
# Note: v5.30 - TLS handled by Nginx stream block, Xray uses plaintext inbound
# =============================================================================
generate_socks5_inbound_json() {
    # v5.33: Single-container architecture with host networking
    # Architecture: Client → familytraffic nginx (TLS, 0.0.0.0:1080) → Xray (plaintext, 127.0.0.1:10800)
    #
    # BUG-3 fix: listen on 127.0.0.1 (loopback only), NOT 0.0.0.0
    # With network_mode:host, 0.0.0.0:10800 would be exposed on all interfaces.
    # 127.0.0.1 ensures only local nginx (same host) can reach the plaintext inbound.
    # - Nginx handles TLS termination on public port 1080
    # - Xray handles authentication (username/password MANDATORY)
    # - No TLS streamSettings in Xray config (handled by Nginx)

    cat <<'EOF'
  ,{
    "tag": "socks5-proxy",
    "listen": "127.0.0.1",
    "port": 10800,
    "protocol": "socks",
    "settings": {
      "auth": "password",
      "accounts": [],
      "udp": false,
      "ip": "0.0.0.0"
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }
EOF
}

# =============================================================================
# FUNCTION: generate_http_inbound_json
# =============================================================================
# Description: Generate HTTP proxy inbound configuration for Xray
# Returns: JSON string for HTTP inbound (to be appended to inbounds array)
# Related: TASK-11.2 (HTTP Proxy Inbound Configuration)
# Note: v5.30 - TLS handled by Nginx stream block, Xray uses plaintext inbound
# =============================================================================
generate_http_inbound_json() {
    # v5.33: Single-container architecture with host networking
    # Architecture: Client → familytraffic nginx (TLS, 0.0.0.0:8118) → Xray (plaintext, 127.0.0.1:18118)
    #
    # BUG-3 fix: listen on 127.0.0.1 (loopback only), NOT 0.0.0.0
    # With network_mode:host, 0.0.0.0:18118 would be exposed on all interfaces.
    # 127.0.0.1 ensures only local nginx (same host) can reach the plaintext inbound.
    # - Nginx handles TLS termination on public port 8118
    # - Xray handles authentication (username/password MANDATORY)
    # - No TLS streamSettings in Xray config (handled by Nginx)

    cat <<'EOF'
  ,{
    "tag": "http-proxy",
    "listen": "127.0.0.1",
    "port": 18118,
    "protocol": "http",
    "settings": {
      "accounts": [],
      "allowTransparent": false,
      "userLevel": 0
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }
EOF
}

# =============================================================================
# FUNCTION: generate_websocket_inbound_json (v5.30)
# =============================================================================
# Description: Returns JSON for VLESS WebSocket inbound (no TLS — Nginx terminates)
# Port: 8444 (internal Docker network only — familytraffic_nginx proxies from 443 SNI)
# =============================================================================
generate_websocket_inbound_json() {
    cat <<'EOF'
  ,{
    "port": 8444,
    "protocol": "vless",
    "tag": "vless-websocket",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vless-ws",
        "headers": {}
      }
    }
  }
EOF
}

# =============================================================================
# FUNCTION: generate_xhttp_inbound_json (v5.31)
# =============================================================================
# Description: Returns JSON for VLESS XHTTP/SplitHTTP inbound (no TLS — Nginx terminates)
# Port: 8445 (internal Docker network only)
# Requires: Xray-core >= 24.9 (satisfied by teddysun/xray:24.11.30)
# =============================================================================
generate_xhttp_inbound_json() {
    cat <<'EOF'
  ,{
    "port": 8445,
    "protocol": "vless",
    "tag": "vless-xhttp",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "splithttp",
      "splithttpSettings": {
        "path": "/api/v2",
        "maxUploadSize": 1000000,
        "maxConcurrentUploads": 10,
        "minUploadIntervalMs": 0
      }
    }
  }
EOF
}

# =============================================================================
# FUNCTION: generate_grpc_inbound_json (v5.32)
# =============================================================================
# Description: Returns JSON for VLESS gRPC inbound (TLS terminated by Nginx http block)
# Port: 8446 (internal Docker network only)
# =============================================================================
generate_grpc_inbound_json() {
    cat <<'EOF'
  ,{
    "port": 8446,
    "protocol": "vless",
    "tag": "vless-grpc",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "grpc",
      "grpcSettings": {
        "serviceName": "GunService",
        "multiMode": false,
        "idle_timeout": 60,
        "health_check_timeout": 20
      },
      "security": "none"
    }
  }
EOF
}

# =============================================================================
# FUNCTION: create_xray_config
# =============================================================================
# Description: Create Xray configuration file (xray_config.json)
# Uses: PRIVATE_KEY, SHORT_ID, REALITY_DEST, REALITY_DEST_PORT, VLESS_PORT
# Arguments:
#   $1 - enable_proxy (optional): "true" to enable SOCKS5/HTTP proxy support
#                                 "false" (default) for VLESS only
#   $2 - enable_tier2 (optional): "true" to add WS/XHTTP/gRPC Tier 2 inbounds
#                                 "false" (default) — only Reality inbound
# Returns: 0 on success, 1 on failure
# Updated: TASK-11.1 - Added proxy support parameter
# Updated: v5.33 - Added policy section with increased limits for proxy usage
#          - handshakeTimeout: 15s (was 4s default)
#          - connIdle: 3600s (1 hour, was 300s/5min default)
#          - bufferSize: 10240 KB (10 MB, was 512 KB default)
# =============================================================================
create_xray_config() {
    local enable_proxy="${1:-false}"
    local enable_tier2="${2:-false}"   # v5.30: Tier 2 transports (WS/XHTTP/gRPC) flag
    echo -e "${CYAN}[4/12] Creating Xray configuration...${NC}"

    # Validate required variables
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$SHORT_ID" ]] || \
       [[ -z "$REALITY_DEST" ]] || [[ -z "$REALITY_DEST_PORT" ]] || \
       [[ -z "$VLESS_PORT" ]]; then
        echo -e "${RED}Missing required configuration parameters${NC}" >&2
        return 1
    fi

    # Create Xray configuration
    local _xray_loglevel="warning"
    local _xray_access=""
    if [[ "${FT_DEBUG:-false}" == "true" ]]; then
        _xray_loglevel="debug"
        _xray_access="/var/log/xray/access.log"
    fi

    cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "${_xray_loglevel}",
    "access": "${_xray_access}",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "${DETECTED_DNS_PRIMARY:-1.1.1.1}",
      "${DETECTED_DNS_SECONDARY:-8.8.8.8}",
      "${DETECTED_DNS_TERTIARY:-77.88.8.8}"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [{
    "port": ${VLESS_PORT},
    "protocol": "vless",
    "tag": "vless-reality",
    "settings": {
      "clients": [],
      "decryption": "none",
      "fallbacks": [
        {
          "dest": "127.0.0.1:80"
        }
      ]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${REALITY_DEST}:${REALITY_DEST_PORT}",
        "xver": 0,
        "serverNames": [
          "${REALITY_DEST}",
          "www.google.com",
          "www.microsoft.com",
          "www.apple.com",
          "www.cloudflare.com",
          "www.amazon.com",
          "www.youtube.com",
          "www.github.com",
          "www.wikipedia.org",
          "www.netflix.com",
          "www.linkedin.com"
        ],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}", ""]
      }
    }
  }$(if [[ "$enable_proxy" == "true" ]]; then
    generate_socks5_inbound_json
    generate_http_inbound_json
fi)$(if [[ "$enable_tier2" == "true" ]]; then
    generate_websocket_inbound_json
    generate_xhttp_inbound_json
    generate_grpc_inbound_json
fi)],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "AsIs"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]$(if [[ "$enable_proxy" == "true" ]]; then
    generate_routing_json
fi),
  "policy": {
    "levels": {
      "0": {
        "handshakeTimeout": 15,
        "connIdle": 3600,
        "uplinkOnly": 5,
        "downlinkOnly": 10,
        "bufferSize": 10240
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
EOF

    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        echo -e "${RED}Failed to create ${XRAY_CONFIG}${NC}" >&2
        return 1
    fi

    # Validate JSON syntax
    if ! jq empty "${XRAY_CONFIG}" 2>/dev/null; then
        echo -e "${RED}Invalid JSON in ${XRAY_CONFIG}${NC}" >&2
        return 1
    fi

    # Set permissions to 644 (readable by Xray container user: nobody)
    chmod 644 "${XRAY_CONFIG}"
    chown root:root "${XRAY_CONFIG}" 2>/dev/null || true

    echo "  ✓ Configuration file: ${XRAY_CONFIG}"
    echo "  ✓ Listen port: ${VLESS_PORT}"
    echo "  ✓ Destination: ${REALITY_DEST}:${REALITY_DEST_PORT}"
    echo "  ✓ Fallback to Nginx configured"
    if [[ -n "${DETECTED_DNS_PRIMARY}" ]]; then
        echo "  ✓ DNS Servers:"
        echo "    - Primary:   ${DETECTED_DNS_PRIMARY}"
        echo "    - Secondary: ${DETECTED_DNS_SECONDARY}"
        echo "    - Tertiary:  ${DETECTED_DNS_TERTIARY}"
    else
        echo "  ✓ DNS Servers: 1.1.1.1, 8.8.8.8, 77.88.8.8 (default fallback)"
    fi
    echo "  ✓ Policy Limits (v5.33 - optimized for proxy usage):"
    echo "    - Handshake Timeout: 15s"
    echo "    - Connection Idle: 3600s (1 hour)"
    echo "    - Buffer Size: 10240 KB (10 MB)"

    if [[ "$enable_proxy" == "true" ]]; then
        if [[ "${ENABLE_PUBLIC_PROXY:-false}" == "true" ]]; then
            # v3.3: TLS-encrypted public proxy
            local domain="${DOMAIN:-SERVER_DOMAIN}"
            echo "  ✓ SOCKS5 Proxy (0.0.0.0:1080) - TLS-ENCRYPTED PUBLIC ACCESS"
            echo "  ✓ HTTP Proxy (0.0.0.0:8118) - TLS-ENCRYPTED PUBLIC ACCESS"
            echo "  ✓ TLS Certificate: ${domain}"
            echo "  ⚠️  SOCKS5 URI: socks5s://user:pass@${domain}:1080"
            echo "  ⚠️  HTTP URI: https://user:pass@${domain}:8118"
            echo "  ⚠️  WARNING: Proxies require TLS-capable clients (v3.3)"
        else
            # v3.1: Localhost-only proxy (no TLS needed)
            echo "  ✓ SOCKS5 Proxy (127.0.0.1:1080) - LOCALHOST ONLY"
            echo "  ✓ HTTP Proxy (127.0.0.1:8118) - LOCALHOST ONLY"
            echo "  ℹ️  Access via VPN connection only"
        fi
    fi

    # Repopulate proxy accounts from users.json to prevent open proxy access.
    # xray HTTP inbound has no "auth" flag — empty accounts = no auth required.
    # This sync ensures accounts survive config regeneration (reinstall, setup).
    if [[ "$enable_proxy" == "true" ]] && declare -f rebuild_proxy_accounts_from_users_json >/dev/null 2>&1; then
        rebuild_proxy_accounts_from_users_json || log_warning "Proxy accounts rebuild failed (non-critical, re-run 'familytraffic setup' if proxy auth is broken)"
    fi

    echo -e "${GREEN}✓ Xray configuration created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: configure_proxy_firewall_rules
# =============================================================================
# Description: Open UFW ports for public proxy access with rate limiting
# Arguments:
#   None (uses global ENABLE_PUBLIC_PROXY variable)
# Returns: 0 on success, 1 on failure
# Related: v3.2 Public Proxy Support - TASK-2.2
# =============================================================================
configure_proxy_firewall_rules() {
    if [[ "${ENABLE_PUBLIC_PROXY:-false}" != "true" ]]; then
        echo "  ℹ️  Public proxy disabled, skipping firewall rules"
        return 0
    fi

    echo -e "${CYAN}Configuring firewall for public proxy...${NC}"

    # Ensure UFW is active
    if ! ufw status | grep -q "Status: active"; then
        echo -e "${RED}UFW is not active${NC}" >&2
        return 1
    fi

    # Check if SOCKS5 port rule already exists
    if ! ufw status numbered | grep -q "1080/tcp"; then
        echo "  Adding SOCKS5 port (1080/tcp) with rate limiting..."
        if ! ufw limit 1080/tcp comment 'VLESS SOCKS5 Proxy (rate-limited)'; then
            echo -e "${RED}Failed to add SOCKS5 firewall rule${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}  ✓ SOCKS5 port opened with rate limiting${NC}"
    else
        echo "  ✓ SOCKS5 port already open"
    fi

    # Check if HTTP port rule already exists
    if ! ufw status numbered | grep -q "8118/tcp"; then
        echo "  Adding HTTP port (8118/tcp) with rate limiting..."
        if ! ufw limit 8118/tcp comment 'VLESS HTTP Proxy (rate-limited)'; then
            echo -e "${RED}Failed to add HTTP firewall rule${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}  ✓ HTTP port opened with rate limiting${NC}"
    else
        echo "  ✓ HTTP port already open"
    fi

    # No-TLS proxy ports (v5.35)
    if [[ "${PROXY_NOTLS_ENABLED:-false}" == "true" ]]; then
        if ! ufw status numbered | grep -q "1081/tcp"; then
            echo "  Adding SOCKS5 no-TLS port (1081/tcp) with rate limiting..."
            if ! ufw limit 1081/tcp comment 'VLESS SOCKS5 Proxy no-TLS (rate-limited)'; then
                echo -e "${RED}Failed to add SOCKS5 no-TLS firewall rule${NC}" >&2
                return 1
            fi
            echo -e "${GREEN}  ✓ SOCKS5 no-TLS port opened with rate limiting${NC}"
        else
            echo "  ✓ SOCKS5 no-TLS port already open"
        fi

        if ! ufw status numbered | grep -q "8119/tcp"; then
            echo "  Adding HTTP no-TLS port (8119/tcp) with rate limiting..."
            if ! ufw limit 8119/tcp comment 'VLESS HTTP Proxy no-TLS (rate-limited)'; then
                echo -e "${RED}Failed to add HTTP no-TLS firewall rule${NC}" >&2
                return 1
            fi
            echo -e "${GREEN}  ✓ HTTP no-TLS port opened with rate limiting${NC}"
        else
            echo "  ✓ HTTP no-TLS port already open"
        fi
    fi

    # Reload UFW to apply rules
    echo "  Reloading UFW..."
    if ! ufw reload &>/dev/null; then
        echo -e "${YELLOW}Warning: Failed to reload UFW${NC}"
    fi

    echo -e "${GREEN}✓ Firewall configured for public proxy${NC}"
    echo ""
    echo "Active proxy ports:"
    ufw status numbered | grep -E "(1080|1081|8118|8119)/tcp" || true
    echo ""

    return 0
}

# =============================================================================
# FUNCTION: create_users_json
# =============================================================================
# Description: Create empty users.json file
# Returns: 0 on success, 1 on failure
# =============================================================================
create_users_json() {
    echo -e "${CYAN}[5/12] Creating users database...${NC}"

    # Create empty users JSON structure
    cat > "${USERS_JSON}" <<'EOF'
{
  "users": [],
  "metadata": {
    "created": "",
    "last_modified": ""
  }
}
EOF

    # Set timestamps
    local timestamp
    timestamp=$(date -Iseconds)

    # Use temporary file for atomic update
    local temp_file
    temp_file=$(mktemp)

    jq ".metadata.created = \"${timestamp}\" | .metadata.last_modified = \"${timestamp}\"" \
       "${USERS_JSON}" > "$temp_file" && write_preserving_inode "$temp_file" "${USERS_JSON}"

    if [[ ! -f "${USERS_JSON}" ]]; then
        echo -e "${RED}Failed to create ${USERS_JSON}${NC}" >&2
        return 1
    fi

    echo "  ✓ Users database: ${USERS_JSON}"
    echo "  ✓ Initial state: empty (0 users)"

    echo -e "${GREEN}✓ Users database created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: init_proxy_allowed_ips
# =============================================================================
# Description: Initialize proxy_allowed_ips.json with default localhost-only access
# Returns: 0 on success, 1 on failure
# Related: v3.6 Server-Level IP Whitelisting
# =============================================================================
init_proxy_allowed_ips() {
    echo -e "${CYAN}[5.5/13] Initializing proxy IP whitelist...${NC}"

    local proxy_ips_file="${CONFIG_DIR}/proxy_allowed_ips.json"
    local default_ips='["127.0.0.1"]'

    # v5.30: familytraffic_nginx connects via Docker network; default "localhost only"
    # is a conservative starting point — override via proxy_allowed_ips.json

    # Create proxy_allowed_ips.json with appropriate defaults
    cat > "$proxy_ips_file" <<EOF
{
  "allowed_ips": ${default_ips},
  "metadata": {
    "created": "",
    "last_modified": "",
    "description": "Server-level IP whitelist for proxy access (v3.6+v4.0)"
  }
}
EOF

    # Set timestamps
    local timestamp
    timestamp=$(date -Iseconds)

    # Use temporary file for atomic update
    local temp_file
    temp_file=$(mktemp)

    jq ".metadata.created = \"${timestamp}\" | .metadata.last_modified = \"${timestamp}\"" \
       "$proxy_ips_file" > "$temp_file" && write_preserving_inode "$temp_file" "$proxy_ips_file"

    if [[ ! -f "$proxy_ips_file" ]]; then
        echo -e "${RED}Failed to create ${proxy_ips_file}${NC}" >&2
        return 1
    fi

    # Set permissions (600 - root only)
    chmod 600 "$proxy_ips_file" || {
        echo -e "${RED}Failed to set permissions on ${proxy_ips_file}${NC}" >&2
        return 1
    }

    echo "  ✓ Proxy IP whitelist: $proxy_ips_file"
    echo "  ✓ Default: localhost only (127.0.0.1)"
    echo "  ✓ Manage with: vless {show|set|add|remove|reset}-proxy-ips"

    echo -e "${GREEN}✓ Proxy IP whitelist initialized${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_nginx_config
# =============================================================================
# Description: Create Nginx reverse proxy configuration
# Uses: REALITY_DEST, REALITY_DEST_PORT
# Returns: 0 on success, 1 on failure
# =============================================================================
create_nginx_config() {
    echo -e "${CYAN}[6/12] Creating Nginx configuration...${NC}"

    # Validate required variables
    if [[ -z "$REALITY_DEST" ]] || [[ -z "$REALITY_DEST_PORT" ]]; then
        echo -e "${RED}Missing destination configuration${NC}" >&2
        return 1
    fi

    # Debug mode: access_log destination
    local _nginx_access_log="off"
    [[ "${FT_DEBUG:-false}" == "true" ]] && _nginx_access_log="/var/log/nginx/access.log"

    # Create Nginx configuration for fake-site
    cat > "${NGINX_CONFIG}" <<EOF
# Nginx Reverse Proxy Configuration for VLESS Reality Fake-site
# This configuration proxies to ${REALITY_DEST}:${REALITY_DEST_PORT}
# to make the server appear as a normal HTTPS website

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    # Logging
    access_log ${_nginx_access_log};
    error_log /var/log/nginx/error.log;

    # Proxy settings
    location / {
        proxy_pass https://${REALITY_DEST}:${REALITY_DEST_PORT};
        proxy_ssl_server_name on;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;

        # Headers
        proxy_set_header Host ${REALITY_DEST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Timeouts
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;

        # Buffering
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;

        # Caching (1 hour for successful responses)
        proxy_cache_valid 200 1h;
        proxy_cache_valid 301 302 10m;
        proxy_cache_valid 404 1m;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
EOF

    if [[ ! -f "${NGINX_CONFIG}" ]]; then
        echo -e "${RED}Failed to create ${NGINX_CONFIG}${NC}" >&2
        return 1
    fi

    echo "  ✓ Nginx configuration: ${NGINX_CONFIG}"
    echo "  ✓ Proxying to: https://${REALITY_DEST}:${REALITY_DEST_PORT}"
    echo "  ✓ Cache: 1h for 200 OK responses"

    echo -e "${GREEN}✓ Nginx configuration created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: generate_nginx_config_wrapper (v5.30)
# =============================================================================
# Description: Wrapper for lib/nginx_stream_generator.sh::generate_nginx_config()
#              Replaces generate_haproxy_config_wrapper() from v4.3-v5.29
# Uses: DOMAIN, CERT_DOMAIN, VLESS_DIR (from environment / interactive_params.sh)
# Returns: 0 on success, 1 on failure
# =============================================================================
generate_nginx_config_wrapper() {
    echo -e "${CYAN}[6.5/12] Generating Nginx configuration (v5.30, stream+http blocks)...${NC}"

    local cert_domain="${CERT_DOMAIN:-${DOMAIN}}"

    # Create nginx config directory
    mkdir -p "${VLESS_DIR}/config/nginx" || {
        echo -e "${RED}Failed to create ${VLESS_DIR}/config/nginx directory${NC}" >&2
        return 1
    }

    # Create nginx logs directory
    mkdir -p "${VLESS_DIR}/logs/nginx" || {
        echo -e "${YELLOW}Warning: Failed to create ${VLESS_DIR}/logs/nginx directory${NC}"
    }

    # Read no-TLS flag from .env
    local enable_notls="false"
    if [[ -f "${VLESS_DIR}/.env" ]] && grep -q '^PROXY_NOTLS_ENABLED=true' "${VLESS_DIR}/.env" 2>/dev/null; then
        enable_notls="true"
    fi

    # Read debug mode from .env (if already written; during install FT_DEBUG comes from env)
    if [[ -f "${VLESS_DIR}/.env" ]]; then
        local _ft_debug_val
        _ft_debug_val=$(grep -m1 '^FT_DEBUG=' "${VLESS_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        export FT_DEBUG="${_ft_debug_val:-${FT_DEBUG:-false}}"
    fi

    # Generate nginx.conf (Phase 0: no Tier 2 subdomains yet; they are added by transport_manager.sh)
    if ! generate_nginx_config "${cert_domain}" "false" "" "" "" "false" "${enable_notls}" > "${VLESS_DIR}/config/nginx/nginx.conf"; then
        echo -e "${RED}Failed to generate Nginx configuration${NC}" >&2
        return 1
    fi

    echo "  ✓ Nginx config: ${VLESS_DIR}/config/nginx/nginx.conf"
    echo "  ✓ Stream ports: 443 (SNI ssl_preread), 1080 (SOCKS5 TLS), 8118 (HTTP TLS)"
    if [[ "${enable_notls}" == "true" ]]; then
        echo "  ✓ No-TLS ports: 1081 (SOCKS5), 8119 (HTTP) — credentials in cleartext!"
    fi
    echo "  ✓ HTTP block: port 8448 (Tier 2 loopback placeholder)"
    echo "  ✓ Cert domain: ${cert_domain}"

    echo -e "${GREEN}✓ Nginx configuration created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_docker_compose
# =============================================================================
# Description: Copy docker-compose.yml from the repo root to INSTALL_ROOT.
# Returns: 0 on success, 1 on failure
# =============================================================================
create_docker_compose() {
    echo -e "${CYAN}[7/12] Copying Docker Compose configuration from repo...${NC}"

    local compose_src="${SCRIPT_DIR_LIB}/../docker-compose.yml"
    if [[ ! -f "${compose_src}" ]]; then
        echo -e "${RED}Source docker-compose.yml not found: ${compose_src}${NC}" >&2
        return 1
    fi
    # SEC: refuse to follow symlinks (CWE-61 symlink following)
    if [[ -L "${compose_src}" ]]; then
        echo -e "${RED}Symlink detected for docker-compose.yml source — refusing to copy${NC}" >&2
        return 1
    fi

    cp "${compose_src}" "${DOCKER_COMPOSE_FILE}" || {
        echo -e "${RED}Failed to copy docker-compose.yml${NC}" >&2
        return 1
    }

    echo "  ✓ Docker Compose file: ${DOCKER_COMPOSE_FILE} (from repo)"
    echo -e "${GREEN}✓ Docker Compose configuration copied${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_env_file
# =============================================================================
# Description: Create .env file with environment variables
# Uses: REALITY_DEST, REALITY_DEST_PORT, VLESS_PORT, DOCKER_SUBNET, PUBLIC_KEY
# Returns: 0 on success, 1 on failure
# =============================================================================
create_env_file() {
    echo -e "${CYAN}[8/12] Creating environment file...${NC}"

    # Detect external server IP
    local server_ip
    server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "SERVER_IP_NOT_DETECTED")

    cat > "${ENV_FILE}" <<EOF
# VLESS Reality VPN Environment Variables
# Generated: $(date -Iseconds)
# DO NOT commit this file to version control

# Reality Protocol Configuration
REALITY_DEST=${REALITY_DEST}
REALITY_DEST_PORT=${REALITY_DEST_PORT}
VLESS_PORT=${VLESS_PORT}
DOCKER_SUBNET=${DOCKER_SUBNET}

# Server Information (v3.2 - for public proxy configs)
SERVER_IP=${server_ip}

# Proxy Configuration (v3.4)
ENABLE_PROXY=${ENABLE_PROXY:-false}
ENABLE_PUBLIC_PROXY=${ENABLE_PUBLIC_PROXY:-false}
ENABLE_PROXY_TLS=${ENABLE_PROXY_TLS:-false}
PROXY_NOTLS_ENABLED=${PROXY_NOTLS_ENABLED:-false}

# Keys (for reference only, actual keys in ${KEYS_DIR}/)
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}

# Docker Configuration
DOCKER_NETWORK=${DOCKER_NETWORK_NAME}
XRAY_IMAGE=${XRAY_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}

# Paths
INSTALL_ROOT=${INSTALL_ROOT}
VLESS_DIR=${INSTALL_ROOT}
CONFIG_DIR=${CONFIG_DIR}
DATA_DIR=${DATA_DIR}

# TLS Certificate Configuration (v3.3 - for public proxy mode)
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}

# Container Image Configuration (v5.33 familyTraffic)
GHCR_IMAGE=${GHCR_IMAGE:-ghcr.io/OWNER/familytraffic}
FT_IMAGE_TAG=${FT_IMAGE_TAG:-latest}
ACME_EMAIL=${EMAIL:-}

# Debug Mode — set to true to enable access logging (nginx + xray)
# WARNING: access logs record source IPs and timestamps. Keep false in production.
FT_DEBUG=${FT_DEBUG:-false}
EOF

    if [[ ! -f "${ENV_FILE}" ]]; then
        echo -e "${RED}Failed to create ${ENV_FILE}${NC}" >&2
        return 1
    fi

    echo "  ✓ Environment file: ${ENV_FILE}"

    echo -e "${GREEN}✓ Environment file created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: create_docker_network
# =============================================================================
# Description: Create Docker bridge network with specified subnet
# Uses: DOCKER_SUBNET, DOCKER_NETWORK_NAME
# Returns: 0 on success, 1 on failure
# =============================================================================
create_docker_network() {
    echo -e "${CYAN}[9/12] Creating Docker network...${NC}"

    # Check if network already exists
    if docker network inspect "${DOCKER_NETWORK_NAME}" &>/dev/null; then
        echo "  ✓ Network ${DOCKER_NETWORK_NAME} already exists"
        return 0
    fi

    # Create Docker bridge network
    docker network create \
        --driver bridge \
        --subnet "${DOCKER_SUBNET}" \
        "${DOCKER_NETWORK_NAME}" || {
        echo -e "${RED}Failed to create Docker network${NC}" >&2
        return 1
    }

    echo "  ✓ Network name: ${DOCKER_NETWORK_NAME}"
    echo "  ✓ Subnet: ${DOCKER_SUBNET}"
    echo "  ✓ Driver: bridge"

    echo -e "${GREEN}✓ Docker network created${NC}"
    return 0
}

# =============================================================================
# FUNCTION: configure_ufw
# =============================================================================
# Description: Configure UFW firewall with Docker forwarding support
# Uses: VLESS_PORT, DOCKER_SUBNET
# Returns: 0 on success, 1 on failure
# =============================================================================
configure_ufw() {
    echo -e "${CYAN}[10/14] Configuring UFW firewall...${NC}"

    # Check if UFW is installed
    if ! command -v ufw &>/dev/null; then
        echo "  ⚠ UFW not installed, skipping firewall configuration"
        return 0
    fi

    # Backup UFW configuration
    echo "  Creating UFW backup..."
    mkdir -p "${UFW_BACKUP_DIR}"
    if [[ -f "${UFW_AFTER_RULES}" ]]; then
        cp "${UFW_AFTER_RULES}" "${UFW_BACKUP_DIR}/after.rules.backup"
        echo "  ✓ Backup saved to ${UFW_BACKUP_DIR}"
    fi

    # Add Docker forwarding rules to UFW (if not already present)
    if ! grep -q "FAMILYTRAFFIC DOCKER FORWARDING\|VLESS REALITY" "${UFW_AFTER_RULES}" 2>/dev/null; then
        echo "  Adding Docker forwarding rules..."

        cat >> "${UFW_AFTER_RULES}" <<EOF

# BEGIN FAMILYTRAFFIC DOCKER FORWARDING RULES
# Added: $(date -Iseconds)
# v5.33: familytraffic uses network_mode:host — no bridge network, no MASQUERADE needed.
# DOCKER-USER chain kept for Docker daemon compatibility.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN
COMMIT
# WARN-5 fix: *nat POSTROUTING MASQUERADE removed — host networking does not use NAT.
# If MTProxy is enabled as a separate bridge container, its subnet is managed separately.
# END FAMILYTRAFFIC DOCKER FORWARDING RULES
EOF
        echo "  ✓ Docker forwarding rules added"
    else
        echo "  ✓ Docker forwarding rules already present"
    fi

    # v4.3: Remove old reverse proxy port rules (8443-8452) if they exist
    echo "  Removing old reverse proxy port rules (v4.2: 8443-8452)..."
    local removed_count=0
    for old_port in {8443..8452}; do
        if ufw status numbered | grep -q "${old_port}/tcp"; then
            # Find rule number and delete
            local rule_nums=$(ufw status numbered | grep "${old_port}/tcp" | grep -oP '^\[\s*\K\d+' || true)
            if [[ -n "$rule_nums" ]]; then
                for rule_num in $rule_nums; do
                    echo "y" | ufw delete "$rule_num" &>/dev/null || true
                    ((removed_count++))
                done
            fi
        fi
    done
    if [[ $removed_count -gt 0 ]]; then
        echo "  ✓ Removed $removed_count old reverse proxy port rules"
    else
        echo "  ✓ No old reverse proxy port rules found"
    fi

    # v5.30: Allow Nginx external port 443 (NOT VLESS_PORT which is internal 8443)
    # Nginx stream listens on 443 externally via ssl_preread SNI routing, forwards Reality to Xray on 8443
    local nginx_external_port=443
    echo "  Allowing port ${nginx_external_port} (Nginx external SNI frontend)..."
    if ufw status numbered | grep -q "${nginx_external_port}/tcp.*ALLOW"; then
        echo "  ✓ Port ${nginx_external_port}/tcp already allowed"
    else
        ufw allow "${nginx_external_port}/tcp" comment 'Nginx VLESS+Reverse Proxy (v5.30)' || {
            echo -e "${YELLOW}Warning: Failed to add UFW rule${NC}"
        }
        echo "  ✓ Port ${nginx_external_port}/tcp allowed"
    fi

    # v4.3: Ensure ports 9443-9452 are NOT exposed (localhost-only nginx backends)
    echo "  Verifying nginx backend ports (9443-9452) are NOT exposed..."
    local exposed_nginx_ports=()
    for nginx_port in {9443..9452}; do
        if ufw status numbered | grep -q "${nginx_port}/tcp"; then
            exposed_nginx_ports+=("$nginx_port")
        fi
    done
    if [[ ${#exposed_nginx_ports[@]} -gt 0 ]]; then
        echo -e "${YELLOW}  ⚠️  WARNING: Nginx backend ports exposed: ${exposed_nginx_ports[*]}${NC}"
        echo "  These ports should be localhost-only (127.0.0.1) in v4.3"
        echo "  Removing rules..."
        for port in "${exposed_nginx_ports[@]}"; do
            local rule_nums=$(ufw status numbered | grep "${port}/tcp" | grep -oP '^\[\s*\K\d+' || true)
            if [[ -n "$rule_nums" ]]; then
                for rule_num in $rule_nums; do
                    echo "y" | ufw delete "$rule_num" &>/dev/null || true
                done
            fi
        done
        echo "  ✓ Nginx backend ports secured (localhost-only)"
    else
        echo "  ✓ Nginx backend ports are localhost-only (correct)"
    fi

    # Reload UFW to apply changes
    echo "  Reloading UFW..."
    ufw reload || {
        echo -e "${YELLOW}Warning: Failed to reload UFW${NC}"
    }
    echo "  ✓ Docker forwarding configured for ${DOCKER_SUBNET}"

    echo -e "${GREEN}✓ UFW firewall configured (v4.3)${NC}"
    return 0
}

# =============================================================================
# FUNCTION: deploy_containers
# =============================================================================
# Description: Deploy Docker containers using docker-compose
# Returns: 0 on success, 1 on failure
# =============================================================================
deploy_containers() {
    echo -e "${CYAN}[13/14] Deploying Docker containers...${NC}"

    # Pre-flight checks: Verify critical files exist before starting containers
    echo "  Running pre-flight checks..."
    local missing_files=()

    # Check required configuration files
    [[ ! -f "${XRAY_CONFIG}" ]] && missing_files+=("${XRAY_CONFIG}")
    [[ ! -f "${NGINX_CONFIG}" ]] && missing_files+=("${NGINX_CONFIG}")
    [[ ! -f "${DOCKER_COMPOSE_FILE}" ]] && missing_files+=("${DOCKER_COMPOSE_FILE}")
    [[ ! -f "${ENV_FILE}" ]] && missing_files+=("${ENV_FILE}")
    [[ ! -f "${KEYS_DIR}/private.key" ]] && missing_files+=("${KEYS_DIR}/private.key")
    [[ ! -f "${KEYS_DIR}/public.key" ]] && missing_files+=("${KEYS_DIR}/public.key")

    # v5.30: nginx config generated via lib/nginx_stream_generator.sh (called from create_nginx_config)

    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo -e "${RED}✗ Pre-flight check failed: Missing critical files (${#missing_files[@]})${NC}" >&2
        for file in "${missing_files[@]}"; do
            echo "    - $file"
        done
        echo -e "${RED}Cannot start containers without these files${NC}" >&2
        return 1
    fi
    echo "  ✓ All critical files present"

    # Change to installation directory
    cd "${INSTALL_ROOT}" || {
        echo -e "${RED}Failed to change to ${INSTALL_ROOT}${NC}" >&2
        return 1
    }

    # Pull images
    echo "  Pulling Docker images..."
    docker compose pull || {
        echo -e "${RED}Failed to pull Docker images${NC}" >&2
        return 1
    }
    echo "  ✓ Images pulled"

    # Start containers
    echo "  Starting containers..."
    docker compose up -d || {
        echo -e "${RED}Failed to start containers${NC}" >&2
        return 1
    }

    # Wait for containers to be healthy
    echo "  Waiting for containers to start..."
    sleep 5

    # v5.33: Check single familytraffic container (nginx + xray + supervisord)
    local ft_status
    ft_status=$(docker inspect "familytraffic" -f '{{.State.Status}}' 2>/dev/null || echo "not-found")
    if [[ "$ft_status" == "running" ]]; then
        echo "  ✓ familytraffic container running"

        # Check healthcheck status
        local ft_health
        ft_health=$(docker inspect "familytraffic" -f '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
        if [[ "$ft_health" == "healthy" ]]; then
            echo "  ✓ familytraffic container healthy"
        elif [[ "$ft_health" == "starting" ]]; then
            echo "  ℹ familytraffic health: starting (will be checked later)"
        elif [[ "$ft_health" != "no-healthcheck" ]]; then
            echo -e "${YELLOW}  ⚠ familytraffic health: $ft_health${NC}"
        fi

        # Check for bind errors in logs
        local ft_logs
        ft_logs=$(docker logs "familytraffic" 2>&1 | tail -20)
        if echo "$ft_logs" | grep -q "bind() to.*failed"; then
            echo -e "${RED}familytraffic has bind errors (check logs)${NC}" >&2
            docker compose logs familytraffic
            return 1
        fi
        if echo "$ft_logs" | grep -q "nginx: \[emerg\]"; then
            echo -e "${RED}familytraffic nginx has critical errors${NC}" >&2
            docker compose logs familytraffic
            return 1
        fi
    else
        echo -e "${RED}familytraffic container failed to start (status: $ft_status)${NC}" >&2
        docker compose logs familytraffic
        return 1
    fi

    echo -e "${GREEN}✓ Containers deployed successfully${NC}"
    return 0
}

# =============================================================================
# FUNCTION: install_cli_tools
# =============================================================================
# Description: Install CLI management tools and create symlinks
# Returns: 0 on success, 1 on failure
# =============================================================================
install_cli_tools() {
    echo -e "${CYAN}[14/14] Installing CLI tools...${NC}"

    # Get the project root (assuming script is in lib/ subdirectory)
    local project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local cli_source="${project_root}/scripts/familytraffic"

    # Check if CLI script exists in project
    if [[ ! -f "$cli_source" ]]; then
        echo -e "${YELLOW}  ⚠ CLI script not found in project: $cli_source${NC}"
        echo "  ℹ CLI tool installation skipped"
        return 0
    fi

    # Copy CLI script to installation directory
    cp "$cli_source" "${SCRIPTS_DIR}/familytraffic" || {
        echo -e "${RED}Failed to copy CLI script${NC}" >&2
        return 1
    }

    # Make it executable
    chmod 755 "${SCRIPTS_DIR}/familytraffic" || {
        echo -e "${RED}Failed to set execute permission${NC}" >&2
        return 1
    }

    # Create symlink in /usr/local/bin
    ln -sf "${SCRIPTS_DIR}/familytraffic" /usr/local/bin/familytraffic || {
        echo -e "${RED}Failed to create symlink${NC}" >&2
        return 1
    }

    # v5.23: Install familytraffic-external-proxy CLI tool
    local external_proxy_cli_source="${project_root}/scripts/familytraffic-external-proxy"
    if [[ -f "$external_proxy_cli_source" ]]; then
        cp "$external_proxy_cli_source" "${SCRIPTS_DIR}/familytraffic-external-proxy" || {
            echo -e "${RED}Failed to copy familytraffic-external-proxy script${NC}" >&2
            return 1
        }

        # Make it executable
        chmod 755 "${SCRIPTS_DIR}/familytraffic-external-proxy" || {
            echo -e "${RED}Failed to set execute permission on familytraffic-external-proxy${NC}" >&2
            return 1
        }

        # Create symlink in /usr/local/bin
        ln -sf "${SCRIPTS_DIR}/familytraffic-external-proxy" /usr/local/bin/familytraffic-external-proxy || {
            echo -e "${RED}Failed to create familytraffic-external-proxy symlink${NC}" >&2
            return 1
        }

        echo "  ✓ familytraffic-external-proxy installed"
    else
        echo -e "${YELLOW}  ⚠ familytraffic-external-proxy script not found: $external_proxy_cli_source${NC}"
        echo "  ℹ familytraffic-external-proxy installation skipped (v5.23 feature)"
    fi

    # Install familytraffic-mtproxy CLI tool
    local mtproxy_cli_source="${project_root}/scripts/familytraffic-mtproxy"
    if [[ -f "$mtproxy_cli_source" ]]; then
        cp "$mtproxy_cli_source" "${SCRIPTS_DIR}/familytraffic-mtproxy" || {
            echo -e "${RED}Failed to copy familytraffic-mtproxy script${NC}" >&2
            return 1
        }
        chmod 755 "${SCRIPTS_DIR}/familytraffic-mtproxy" || {
            echo -e "${RED}Failed to set execute permission on familytraffic-mtproxy${NC}" >&2
            return 1
        }
        ln -sf "${SCRIPTS_DIR}/familytraffic-mtproxy" /usr/local/sbin/familytraffic-mtproxy || {
            echo -e "${RED}Failed to create familytraffic-mtproxy symlink${NC}" >&2
            return 1
        }
        echo "  ✓ familytraffic-mtproxy installed"
    else
        echo -e "${YELLOW}  ⚠ familytraffic-mtproxy script not found: $mtproxy_cli_source${NC}"
    fi

    # v5.20: Copy ALL lib modules automatically (except installation-only modules)
    # Installation-only modules (excluded from copy):
    local exclude_modules=(
        "dependencies.sh"       # Only for install.sh
        "os_detection.sh"       # Only for install.sh
        "interactive_params.sh" # Only for install.sh
        "old_install_detect.sh" # Only for install.sh
        "sudoers_info.sh"       # Only for install.sh
        "verification.sh"       # Only for install.sh
        "orchestrator.sh"       # This file itself
        "network_params.sh"     # Only for install.sh
    )

    # Executable modules (need 755 permissions)
    local executable_modules=(
        "security_tests.sh"
    )

    echo "  📁 Copying ALL library modules from ${project_root}/lib/..."
    local copied_count=0
    local skipped_count=0

    # Copy all *.sh files from lib/
    for lib_file in "${project_root}/lib/"*.sh; do
        local module=$(basename "$lib_file")

        # Check if module should be excluded
        local should_exclude=false
        for excluded in "${exclude_modules[@]}"; do
            if [[ "$module" == "$excluded" ]]; then
                should_exclude=true
                echo "  ⊘ Skipped ${module} (installation-only)"
                ((skipped_count++))
                break
            fi
        done

        if [[ "$should_exclude" == "true" ]]; then
            continue
        fi

        # Copy module
        if [[ -f "$lib_file" ]]; then
            cp "$lib_file" "${INSTALL_ROOT}/lib/" || {
                echo -e "${RED}Failed to copy ${module}${NC}" >&2
                return 1
            }

            # Set permissions based on module type
            local is_executable=false
            for exec_module in "${executable_modules[@]}"; do
                if [[ "$module" == "$exec_module" ]]; then
                    is_executable=true
                    break
                fi
            done

            if [[ "$is_executable" == "true" ]]; then
                chmod 755 "${INSTALL_ROOT}/lib/${module}" || {
                    echo -e "${RED}Failed to set permissions on ${module}${NC}" >&2
                    return 1
                }
                echo "  ✓ Copied ${module} (executable: 755)"
            else
                chmod 644 "${INSTALL_ROOT}/lib/${module}" || {
                    echo -e "${RED}Failed to set permissions on ${module}${NC}" >&2
                    return 1
                }
                echo "  ✓ Copied ${module} (sourced: 644)"
            fi

            ((copied_count++))
        fi
    done

    echo "  📊 Summary: ${copied_count} modules copied, ${skipped_count} skipped"

    echo "  ✓ CLI scripts installed in ${SCRIPTS_DIR}"
    echo "  ✓ Symlinks created in /usr/local/bin and /usr/local/sbin"
    echo "  ✓ Commands available: familytraffic, familytraffic-external-proxy, familytraffic-mtproxy"

    echo -e "${GREEN}✓ CLI tools installed${NC}"
    return 0
}

# =============================================================================
# FUNCTION: set_permissions
# =============================================================================
# Description: Set appropriate file and directory permissions
# Returns: 0 on success, 1 on failure
# =============================================================================
set_permissions() {
    echo -e "${CYAN}[11/14] Setting file permissions...${NC}"

    # Ensure INSTALL_ROOT and all subdirectories are owned by root
    # (directory may have been pre-created by a non-root CI/CD step or SSH user)
    chown -R root:root "${INSTALL_ROOT}" 2>/dev/null || {
        echo -e "${RED}Failed to set ownership of ${INSTALL_ROOT} to root${NC}" >&2
        return 1
    }
    echo "  ✓ Ownership: ${INSTALL_ROOT} → root:root"

    # Sensitive directories: 700 (root only)
    # EXCEPTION: CONFIG_DIR must be 755 to allow container users to read files inside
    # Set permissions on each directory individually to ensure all exist
    for sensitive_dir in "${DATA_DIR}" "${DATA_DIR}/clients" "${DATA_DIR}/backups" "${KEYS_DIR}" "${INSTALL_ROOT}/backup"; do
        if [[ -d "$sensitive_dir" ]]; then
            chmod 700 "$sensitive_dir" 2>/dev/null || true
        fi
    done

    # CONFIG_DIR and subdirectories: 755 (readable by container users)
    # This allows Xray (root) and Nginx containers to read config files
    if [[ -d "${CONFIG_DIR}" ]]; then
        chmod 755 "${CONFIG_DIR}" 2>/dev/null || true
    fi

    # Sensitive files: 600 (root read/write only)
    find "${CONFIG_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
    find "${KEYS_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
    chmod 600 "${ENV_FILE}" 2>/dev/null || true

    # v5.30: Nginx config must be readable by nginx container user
    if [[ -f "${CONFIG_DIR}/nginx/nginx.conf" ]]; then
        chmod 644 "${CONFIG_DIR}/nginx/nginx.conf" 2>/dev/null || {
            echo -e "  ${YELLOW}⚠ WARNING: Failed to set permissions on nginx.conf${NC}" >&2
        }
        local nginx_conf_perms
        nginx_conf_perms=$(stat -c '%a' "${CONFIG_DIR}/nginx/nginx.conf" 2>/dev/null || echo "000")
        if [[ "$nginx_conf_perms" == "644" ]]; then
            echo "  ✓ nginx.conf: 644 (readable by nginx container)"
        else
            echo -e "  ${RED}✗ nginx.conf: $nginx_conf_perms (EXPECTED 644)${NC}" >&2
        fi
    else
        echo -e "  ${YELLOW}⚠ WARNING: nginx.conf not found at ${CONFIG_DIR}/nginx/nginx.conf${NC}" >&2
    fi

    # EXCEPTION: Xray config must be world-readable (chmod 644)
    # After v5.18, xray container runs as root (removed user: nobody from docker-compose)
    if [[ -f "${XRAY_CONFIG}" ]]; then
        echo "  → Setting permissions on ${XRAY_CONFIG}..."
        chmod 644 "${XRAY_CONFIG}" 2>/dev/null || {
            echo -e "  ${RED}✗ CRITICAL: Failed to chmod 644 ${XRAY_CONFIG}${NC}" >&2
            echo -e "  ${RED}  This will cause familytraffic_xray container to fail!${NC}" >&2
            return 1
        }
        # Verify permissions were set correctly
        local xray_perms=$(stat -c '%a' "${XRAY_CONFIG}" 2>/dev/null || echo "000")
        if [[ "$xray_perms" == "644" ]]; then
            echo -e "  ${GREEN}✓ xray_config.json: 644 (readable by container)${NC}"
        else
            echo -e "  ${RED}✗ CRITICAL: xray_config.json: $xray_perms (EXPECTED 644)${NC}" >&2
            echo -e "  ${RED}  familytraffic_xray container will fail to start!${NC}" >&2
            return 1
        fi
    else
        echo -e "  ${RED}✗ CRITICAL: XRAY_CONFIG not found: ${XRAY_CONFIG}${NC}" >&2
        echo -e "  ${RED}  Variable: XRAY_CONFIG=${XRAY_CONFIG}${NC}" >&2
        return 1
    fi

    # Readable directories: 755
    chmod 755 "${LOGS_DIR}" "${SCRIPTS_DIR}" "${FAKESITE_DIR}" \
              "${DOCS_DIR}" "${TESTS_DIR}" 2>/dev/null || true

    # Set ownership for xray logs (container runs as root after v5.18 fix)
    # xray container must run as root to avoid permission denied errors with config/logs
    if [[ -d "${LOGS_DIR}/xray" ]]; then
        chown -R root:root "${LOGS_DIR}/xray" 2>/dev/null || true
        chmod 755 "${LOGS_DIR}/xray" 2>/dev/null || true
    fi

    # Set ownership for nginx logs (containers run as user: nginx = UID 101)
    # This allows nginx containers to write logs without permission errors
    if [[ -d "${LOGS_DIR}/nginx" ]]; then
        chown -R 101:101 "${LOGS_DIR}/nginx" 2>/dev/null || true
        chmod 755 "${LOGS_DIR}/nginx" 2>/dev/null || true
    fi
    if [[ -d "${LOGS_DIR}/fake-site" ]]; then
        chown -R 101:101 "${LOGS_DIR}/fake-site" 2>/dev/null || true
        chmod 755 "${LOGS_DIR}/fake-site" 2>/dev/null || true
    fi

    # Readable files: 644
    find "${LOGS_DIR}" -type f -exec chmod 644 {} \; 2>/dev/null || true
    chmod 644 "${DOCKER_COMPOSE_FILE}" 2>/dev/null || true
    chmod 644 "${NGINX_CONFIG}" 2>/dev/null || true

    # Executable scripts: 755
    find "${SCRIPTS_DIR}" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true

    echo "  ✓ Sensitive files: 600 (root only)"
    echo "  ✓ Config/keys directories: 700 (root only)"
    echo "  ✓ Xray logs ownership: root:root (container runs as root since v5.18)"
    echo "  ✓ Nginx logs ownership: nginx:nginx (101:101)"
    echo "  ✓ Logs/scripts: 755/644 (readable)"

    echo -e "${GREEN}✓ Permissions set${NC}"
    return 0
}

# =============================================================================
# FUNCTION: verify_file_permissions
# =============================================================================
# Description: Verify critical file permissions after installation
# Returns: 0 on success, 1 if critical issues found
# =============================================================================
verify_file_permissions() {
    echo ""
    echo -e "${CYAN}[12/14] Verifying critical file permissions...${NC}"

    local ISSUES=0
    local WARNINGS=0

    # Check CONFIG_DIR directory permissions (CRITICAL)
    if [[ -d "${CONFIG_DIR}" ]]; then
        local config_dir_perms=$(stat -c '%a' "${CONFIG_DIR}" 2>/dev/null || echo "000")
        if [[ "$config_dir_perms" == "755" ]]; then
            echo -e "  ${GREEN}✓ config directory: 755 (OK)${NC}"
        else
            echo -e "  ${RED}✗ CRITICAL: config directory: $config_dir_perms (EXPECTED 755)${NC}"
            echo -e "  ${RED}  → Containers cannot read config files (permission denied)${NC}"
            echo -e "  ${YELLOW}  → Manual fix: sudo chmod 755 ${CONFIG_DIR}${NC}"
            ((ISSUES++))
        fi
    else
        echo -e "  ${RED}✗ CRITICAL: config directory not found${NC}"
        ((ISSUES++))
    fi

    # Check xray_config.json (CRITICAL)
    if [[ -f "${XRAY_CONFIG}" ]]; then
        local xray_perms=$(stat -c '%a' "${XRAY_CONFIG}" 2>/dev/null || echo "000")
        if [[ "$xray_perms" == "644" ]]; then
            echo -e "  ${GREEN}✓ xray_config.json: 644 (OK)${NC}"
        else
            echo -e "  ${RED}✗ CRITICAL: xray_config.json: $xray_perms (EXPECTED 644)${NC}"
            echo -e "  ${RED}  → familytraffic_xray container will fail to start!${NC}"
            echo -e "  ${YELLOW}  → Manual fix: sudo chmod 644 ${XRAY_CONFIG}${NC}"
            ((ISSUES++))
        fi
    else
        echo -e "  ${RED}✗ CRITICAL: xray_config.json not found${NC}"
        ((ISSUES++))
    fi

    # Check nginx/nginx.conf (CRITICAL — v5.30: replaces haproxy.cfg)
    if [[ -f "${CONFIG_DIR}/nginx/nginx.conf" ]]; then
        local nginx_perms
        nginx_perms=$(stat -c '%a' "${CONFIG_DIR}/nginx/nginx.conf" 2>/dev/null || echo "000")
        if [[ "$nginx_perms" == "644" ]]; then
            echo -e "  ${GREEN}✓ nginx/nginx.conf: 644 (OK)${NC}"
        else
            echo -e "  ${YELLOW}⚠ WARNING: nginx/nginx.conf: $nginx_perms (EXPECTED 644)${NC}"
            echo -e "  ${YELLOW}  → familytraffic_nginx container may fail to load config${NC}"
            ((WARNINGS++))
        fi
    else
        echo -e "  ${YELLOW}⚠ WARNING: nginx/nginx.conf not found${NC}"
        ((WARNINGS++))
    fi

    # Check docker-compose.yml
    if [[ -f "${DOCKER_COMPOSE_FILE}" ]]; then
        local compose_perms=$(stat -c '%a' "${DOCKER_COMPOSE_FILE}" 2>/dev/null || echo "000")
        if [[ "$compose_perms" == "644" ]]; then
            echo -e "  ${GREEN}✓ docker-compose.yml: 644 (OK)${NC}"
        else
            echo -e "  ${YELLOW}⚠ WARNING: docker-compose.yml: $compose_perms (EXPECTED 644)${NC}"
            ((WARNINGS++))
        fi
    fi

    # Check xray logs directory ownership (v5.18: changed to root after removing user: nobody)
    if [[ -d "${LOGS_DIR}/xray" ]]; then
        local xray_log_owner=$(stat -c '%u:%g' "${LOGS_DIR}/xray" 2>/dev/null || echo "0:0")
        if [[ "$xray_log_owner" == "0:0" ]]; then
            echo -e "  ${GREEN}✓ xray logs: owned by root:root (0:0) - container runs as root${NC}"
        else
            echo -e "  ${YELLOW}⚠ WARNING: xray logs: $xray_log_owner (EXPECTED 0:0 after v5.18)${NC}"
            echo -e "  ${YELLOW}  → Xray container may fail to write logs${NC}"
            ((WARNINGS++))
        fi
    fi

    # Summary
    echo ""
    if [[ $ISSUES -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}✓ All critical permissions verified successfully${NC}"
        return 0
    elif [[ $ISSUES -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Verification completed with $WARNINGS warning(s)${NC}"
        echo -e "${YELLOW}  System may still function, but review warnings above${NC}"
        return 0
    else
        echo -e "${RED}✗ Verification FAILED with $ISSUES critical issue(s) and $WARNINGS warning(s)${NC}"
        echo -e "${RED}  Installation may not work correctly!${NC}"
        echo ""
        echo -e "${YELLOW}Run manual fixes above, then restart processes inside the container:${NC}"
        echo -e "${YELLOW}  docker exec familytraffic supervisorctl restart xray${NC}"
        echo -e "${YELLOW}  docker exec familytraffic supervisorctl restart nginx${NC}"
        echo -e "${YELLOW}  # Or restart the entire container:${NC}"
        echo -e "${YELLOW}  docker restart familytraffic${NC}"
        return 1
    fi
}

# =============================================================================
# FUNCTION: setup_xray_logrotate
# =============================================================================
# Description: Install logrotate configuration for xray logs (7-day retention).
#              error.log always rotated; access.log included with missingok (active only when FT_DEBUG=true).
# Returns: 0 on success, 1 on failure
# =============================================================================
setup_xray_logrotate() {
    echo -e "${CYAN}[14.5/12] Setting up logrotate for xray error logs...${NC}"

    local logrotate_file="/etc/logrotate.d/familytraffic-xray"

    cat > "${logrotate_file}" <<'LOGROTATE_EOF'
# familyTraffic — Xray log rotation (7-day retention)
# error.log: always present. access.log: only when FT_DEBUG=true (missingok).

/opt/familytraffic/logs/xray/error.log
/opt/familytraffic/logs/xray/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE_EOF

    if [[ -f "${logrotate_file}" ]]; then
        chmod 644 "${logrotate_file}"
        echo "  ✓ Logrotate installed: ${logrotate_file}"
        echo "  ✓ Retention: 7 days, compressed"
        echo -e "${GREEN}✓ Xray log rotation configured${NC}"
        return 0
    else
        echo -e "${RED}Failed to create ${logrotate_file}${NC}" >&2
        return 1
    fi
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Export main function for use by install.sh
export -f orchestrate_installation

# Export helper functions (for testing and debugging)
export -f create_directory_structure
export -f generate_reality_keys
export -f generate_short_id
export -f generate_socks5_inbound_json
export -f generate_http_inbound_json
export -f create_xray_config
export -f configure_proxy_firewall_rules
export -f create_users_json
export -f create_nginx_config
export -f setup_xray_logrotate
export -f create_docker_compose
export -f create_env_file
export -f create_docker_network
export -f configure_ufw
export -f deploy_containers
export -f install_cli_tools
export -f set_permissions
export -f verify_file_permissions
