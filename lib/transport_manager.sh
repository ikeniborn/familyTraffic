#!/usr/bin/env bash
# lib/transport_manager.sh
# Transport Management (v5.33)
# Manages Tier 2 transport configurations (WebSocket, XHTTP, gRPC)
#
# Functions:
#   1. add_transport()      - Add transport with subdomain routing
#   2. list_transports()    - List configured transports
#   3. remove_transport()   - Remove transport and cleanup
#
# Dependencies:
#   - lib/nginx_stream_generator.sh (generate_nginx_config)
#   - docker (docker exec familytraffic nginx -s reload, docker restart familytraffic)
#
# Data file: ${VLESS_HOME}/data/transports.json

# Transport state file
TRANSPORTS_JSON="${VLESS_HOME:-/opt/familytraffic}/data/transports.json"

# ============================================================================
# INTERNAL: _init_transports_json
# ============================================================================
_init_transports_json() {
    if [[ ! -f "$TRANSPORTS_JSON" ]]; then
        echo '{"transports":[]}' > "$TRANSPORTS_JSON"
        chmod 600 "$TRANSPORTS_JSON"
    fi
}

# ============================================================================
# FUNCTION: add_transport (v5.33)
# ============================================================================
# Description: Add a Tier 2 transport with subdomain routing.
#   - Updates transports.json
#   - Regenerates xray_config.json with Tier 2 inbounds
#   - Regenerates nginx.conf with SNI map entry + http server block
#   - Reloads familytraffic (docker restart) and familytraffic (nginx -s reload)
# Arguments:
#   $1 - transport_type: ws|xhttp|grpc
#   $2 - subdomain: e.g., ws.example.com
# Returns: 0 on success, 1 on failure
# ============================================================================
add_transport() {
    local transport_type="$1"
    local subdomain="$2"

    _init_transports_json

    # Validate type
    case "$transport_type" in
        ws|xhttp|grpc) ;;
        *) log_error "Unknown transport type: $transport_type (must be: ws, xhttp, grpc)"; return 1 ;;
    esac

    # Validate subdomain format (strict RFC 1123 hostname)
    if ! [[ "$subdomain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        log_error "Invalid subdomain: '$subdomain' (expected format: sub.example.com, RFC 1123)"
        return 1
    fi

    # Determine internal Xray port
    local port
    case "$transport_type" in
        ws)    port=8444 ;;
        xhttp) port=8445 ;;
        grpc)  port=8446 ;;
    esac

    # Check if transport type already configured
    local existing
    existing=$(jq -r --arg t "$transport_type" '.transports[] | select(.type == $t) | .subdomain' "$TRANSPORTS_JSON" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log_error "Transport '$transport_type' already configured for subdomain: $existing"
        log_info "Run 'vless remove-transport $transport_type' first to reconfigure"
        return 1
    fi

    # Add to transports.json (with jq empty validation before mv)
    local temp
    temp="${TRANSPORTS_JSON}.tmp.$$"
    jq --arg t "$transport_type" --arg s "$subdomain" --argjson p "$port" \
        '.transports += [{"type": $t, "subdomain": $s, "port": $p, "enabled": true}]' \
        "$TRANSPORTS_JSON" > "$temp" || { rm -f "$temp"; log_error "Failed to update transports.json"; return 1; }
    if ! jq empty "$temp" 2>/dev/null; then
        rm -f "$temp"
        log_error "transports.json update produced invalid JSON"
        return 1
    fi
    write_preserving_inode "$temp" "$TRANSPORTS_JSON"

    log_success "Transport '$transport_type' registered: $subdomain → familytraffic:$port"

    # Source nginx generator (may already be sourced by scripts/vless)
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${lib_dir}/nginx_stream_generator.sh" ]] && source "${lib_dir}/nginx_stream_generator.sh"

    # Surgically append the new Tier 2 inbound to xray_config.json without touching existing clients.
    # IMPORTANT: do NOT call create_xray_config() here — it writes empty "clients": [] and erases users.
    local xray_config="${XRAY_CONFIG:-/opt/familytraffic/config/xray_config.json}"
    if [[ ! -f "$xray_config" ]]; then
        log_error "xray_config.json not found: $xray_config"
        return 1
    fi

    # Check if this inbound tag is already present (idempotency guard)
    local inbound_tag
    case "$transport_type" in
        ws)    inbound_tag="vless-websocket" ;;
        xhttp) inbound_tag="vless-xhttp"    ;;
        grpc)  inbound_tag="vless-grpc"     ;;
    esac
    local already_exists
    already_exists=$(jq -r --arg tag "$inbound_tag" '.inbounds[] | select(.tag == $tag) | .tag' "$xray_config" 2>/dev/null || true)
    if [[ -n "$already_exists" ]]; then
        log_info "Inbound '$inbound_tag' already present in xray_config.json — skipping"
    else
        log_info "Appending '$inbound_tag' inbound to xray_config.json..."
        local new_inbound
        case "$transport_type" in
            ws)
                new_inbound='{"port":8444,"protocol":"vless","tag":"vless-websocket","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"/vless-ws","headers":{}}}}'
                ;;
            xhttp)
                new_inbound='{"port":8445,"protocol":"vless","tag":"vless-xhttp","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"splithttp","splithttpSettings":{"path":"/api/v2","maxUploadSize":1000000,"maxConcurrentUploads":10,"minUploadIntervalMs":0}}}'
                ;;
            grpc)
                new_inbound='{"port":8446,"protocol":"vless","tag":"vless-grpc","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"GunService","multiMode":false,"idle_timeout":60,"health_check_timeout":20},"security":"none"}}'
                ;;
        esac
        local xray_temp
        xray_temp="${xray_config}.tmp.$$"
        jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' \
            "$xray_config" > "$xray_temp" || { rm -f "$xray_temp"; log_error "Failed to append inbound to xray_config.json"; return 1; }
        if ! jq empty "$xray_temp" 2>/dev/null; then
            rm -f "$xray_temp"
            log_error "xray_config.json update produced invalid JSON"
            return 1
        fi
        write_preserving_inode "$xray_temp" "$xray_config"
        log_success "Inbound '$inbound_tag' appended to xray_config.json (existing users preserved)"
    fi

    # Rebuild Nginx config with all current transport subdomains
    _regenerate_nginx_config || return 1

    # Reload containers
    log_info "Reloading containers..."
    docker restart familytraffic 2>/dev/null && log_success "familytraffic restarted" || \
        log_warning "Failed to restart familytraffic (may not be running)"
    docker exec familytraffic nginx -s reload 2>/dev/null && log_success "familytraffic reloaded" || \
        log_warning "Failed to reload familytraffic (may not be running)"

    log_success "Transport '$transport_type' is now active on $subdomain:443"
    return 0
}

# ============================================================================
# INTERNAL: _regenerate_nginx_config
# ============================================================================
# Re-reads all transports from transports.json and regenerates nginx.conf
# ============================================================================
_regenerate_nginx_config() {
    local cert_domain="${CERT_DOMAIN:-${VLESS_DOMAIN:-${DOMAIN:-}}}"
    if [[ -z "$cert_domain" ]]; then
        log_error "CERT_DOMAIN / VLESS_DOMAIN / DOMAIN not set — cannot regenerate nginx.conf"
        return 1
    fi

    local nginx_conf_dir="${VLESS_DIR:-/opt/familytraffic}/config/nginx"
    mkdir -p "$nginx_conf_dir" || {
        log_error "Failed to create $nginx_conf_dir"
        return 1
    }

    # Read all transport subdomains from transports.json
    local ws_sub xhttp_sub grpc_sub
    ws_sub=$(jq -r '.transports[] | select(.type == "ws") | .subdomain' "$TRANSPORTS_JSON" 2>/dev/null || true)
    xhttp_sub=$(jq -r '.transports[] | select(.type == "xhttp") | .subdomain' "$TRANSPORTS_JSON" 2>/dev/null || true)
    grpc_sub=$(jq -r '.transports[] | select(.type == "grpc") | .subdomain' "$TRANSPORTS_JSON" 2>/dev/null || true)

    local has_tier2="false"
    [[ -n "$ws_sub" || -n "$xhttp_sub" || -n "$grpc_sub" ]] && has_tier2="true"

    # Auto-detect MTProxy cloak-port from existing nginx.conf
    local enable_cloak="false"
    if [[ -f "${nginx_conf_dir}/nginx.conf" ]] && grep -q 'listen 4443' "${nginx_conf_dir}/nginx.conf" 2>/dev/null; then
        enable_cloak="true"
    fi

    # Auto-detect no-TLS from .env or existing nginx.conf
    local enable_notls="false"
    local env_file="${VLESS_DIR:-/opt/familytraffic}/.env"
    if [[ -f "$env_file" ]] && grep -q '^PROXY_NOTLS_ENABLED=true' "$env_file" 2>/dev/null; then
        enable_notls="true"
    elif [[ -f "${nginx_conf_dir}/nginx.conf" ]] && grep -q 'listen 1081' "${nginx_conf_dir}/nginx.conf" 2>/dev/null; then
        enable_notls="true"
    fi

    # Read debug mode from .env and export for generate_nginx_config()
    if [[ -f "$env_file" ]]; then
        local _ft_debug_val
        _ft_debug_val=$(grep -m1 '^FT_DEBUG=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        export FT_DEBUG="${_ft_debug_val:-false}"
    fi

    log_info "Regenerating nginx.conf (ws='$ws_sub' xhttp='$xhttp_sub' grpc='$grpc_sub' cloak=$enable_cloak notls=$enable_notls)..."
    local tmp_conf="${nginx_conf_dir}/nginx.conf.tmp"
    if generate_nginx_config "$cert_domain" "$has_tier2" "$ws_sub" "$xhttp_sub" "$grpc_sub" "$enable_cloak" "$enable_notls" \
        > "$tmp_conf"; then
        write_preserving_inode "$tmp_conf" "${nginx_conf_dir}/nginx.conf"
        log_success "nginx.conf regenerated"
    else
        rm -f "$tmp_conf"
        log_error "Failed to regenerate nginx.conf"
        return 1
    fi

    return 0
}

# ============================================================================
# FUNCTION: list_transports (v5.33)
# ============================================================================
# Description: Display all configured Tier 2 transports in tabular format
# Arguments: none
# Returns: 0 always
# ============================================================================
list_transports() {
    _init_transports_json

    local count
    count=$(jq '.transports | length' "$TRANSPORTS_JSON" 2>/dev/null || echo "0")

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Tier 2 Transports"
    echo "═══════════════════════════════════════════════════════"

    if [[ "$count" == "0" ]]; then
        echo "  No transports configured."
        echo "  Use: sudo familytraffic add-transport ws ws.subdomain.example.com"
    else
        printf "  %-8s %-35s %-6s %-8s\n" "TYPE" "SUBDOMAIN" "PORT" "STATUS"
        echo "  ────────────────────────────────────────────────────────"
        jq -r '.transports[] | [.type, .subdomain, (.port|tostring), (if .enabled then "active" else "disabled" end)] | @tsv' \
            "$TRANSPORTS_JSON" | while IFS=$'\t' read -r t s p e; do
            printf "  %-8s %-35s %-6s %-8s\n" "$t" "$s" "$p" "$e"
        done
    fi
    echo ""
    return 0
}

# ============================================================================
# FUNCTION: remove_transport (v5.33)
# ============================================================================
# Description: Remove a Tier 2 transport.
#   - Removes from transports.json
#   - Removes inbound from xray_config.json
#   - Regenerates nginx.conf (removing the server block and SNI map entry)
#   - Restarts familytraffic
# Arguments:
#   $1 - transport_type: ws|xhttp|grpc
# Returns: 0 on success, 1 on failure
# ============================================================================
remove_transport() {
    local transport_type="$1"

    _init_transports_json

    local existing
    existing=$(jq -r --arg t "$transport_type" '.transports[] | select(.type == $t) | .subdomain' "$TRANSPORTS_JSON")

    if [[ -z "$existing" ]]; then
        log_error "Transport '$transport_type' is not configured"
        return 1
    fi

    # Remove from transports.json (with jq empty validation before mv)
    local temp
    temp="${TRANSPORTS_JSON}.tmp.$$"
    jq --arg t "$transport_type" '.transports = [.transports[] | select(.type != $t)]' \
        "$TRANSPORTS_JSON" > "$temp" || { rm -f "$temp"; log_error "Failed to update transports.json"; return 1; }
    if ! jq empty "$temp" 2>/dev/null; then
        rm -f "$temp"
        log_error "transports.json update produced invalid JSON"
        return 1
    fi
    write_preserving_inode "$temp" "$TRANSPORTS_JSON"

    log_success "Transport '$transport_type' removed from transports.json"

    # Remove inbound from xray_config.json
    local xray_config="${XRAY_CONFIG:-/opt/familytraffic/config/xray_config.json}"
    local tag
    case "$transport_type" in
        ws)    tag="vless-websocket" ;;
        xhttp) tag="vless-xhttp" ;;
        grpc)  tag="vless-grpc" ;;
    esac

    if [[ -f "$xray_config" ]]; then
        local xray_temp
        xray_temp="${xray_config}.tmp.$$"
        jq --arg tag "$tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' \
            "$xray_config" > "$xray_temp" || { rm -f "$xray_temp"; log_error "Failed to update xray_config.json"; return 1; }
        if ! jq empty "$xray_temp" 2>/dev/null; then
            rm -f "$xray_temp"
            log_error "xray_config.json update produced invalid JSON"
            return 1
        fi
        write_preserving_inode "$xray_temp" "$xray_config"
        log_success "Removed inbound '$tag' from xray_config.json"
    else
        log_warning "xray_config.json not found — skipping inbound removal"
    fi

    # Regenerate nginx.conf without removed transport
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${lib_dir}/nginx_stream_generator.sh" ]] && source "${lib_dir}/nginx_stream_generator.sh"
    _regenerate_nginx_config || log_warning "Failed to regenerate nginx.conf after removal"

    # Reload containers
    docker restart familytraffic 2>/dev/null && log_success "familytraffic restarted" || \
        log_warning "Failed to restart familytraffic"
    docker exec familytraffic nginx -s reload 2>/dev/null && log_success "familytraffic reloaded" || \
        log_warning "Failed to reload familytraffic"

    log_success "Transport '$transport_type' ($existing) removed successfully"
    return 0
}

export -f add_transport
export -f list_transports
export -f remove_transport
