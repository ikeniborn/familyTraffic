#!/usr/bin/env bash
# Resolve explicit mode before persisted settings. Never source settings.
resolve_proxy_notls() {
    local current="${1-}" saved_file="${2-}" line value saved=""
    case "$current" in
        true|false) printf '%s\n' "$current"; return 0 ;;
        '') ;;
        *) echo 'Invalid explicit PROXY_NOTLS_ENABLED value' >&2; return 1 ;;
    esac
    if [[ -e "$saved_file" ]]; then
        [[ -f "$saved_file" && -r "$saved_file" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                PROXY_NOTLS_ENABLED=*)
                    value="${line#PROXY_NOTLS_ENABLED=}"
                    case "$value" in
                        true|false) ;;
                        *) echo 'Invalid saved PROXY_NOTLS_ENABLED value' >&2; return 1 ;;
                    esac
                    if [[ -n "$saved" && "$saved" != "$value" ]]; then
                        echo 'Conflicting saved PROXY_NOTLS_ENABLED values' >&2
                        return 1
                    fi
                    saved="$value"
                    ;;
            esac
        done < "$saved_file"
    fi
    printf '%s\n' "${saved:-false}"
}

# Reject proxy listeners that could accept anonymous or empty credentials.
validate_proxy_auth_config() {
    if ! jq -e '
        (.inbounds | type == "array") and
        ([.inbounds[] | select(.protocol == "http" or .protocol == "socks") |
            ((.settings.accounts | type == "array" and length > 0) and
             all(.settings.accounts[];
                 (.user | type == "string" and length > 0) and
                 (.pass | type == "string" and length > 0)) and
             (.protocol != "socks" or .settings.auth == "password"))] | all)
    ' "$1" >/dev/null 2>&1; then
        echo 'Proxy authentication preflight failed: require nonempty accounts and SOCKS password authentication' >&2
        return 1
    fi
}

# Stage the private PROXY receivers without rebuilding users, transports, or routes.
stage_proxy_security_config() {
    local current="$1" output="$2" staged
    validate_proxy_auth_config "$current" || return 1
    staged=$(mktemp "${output}.tmp.XXXXXX") || return 1
    if ! jq -e '
        def proxy_tags: ["http-proxy", "socks5-proxy"];
        def proxy_rule: (.inboundTag == null) or any(.inboundTag[]?; . as $tag | proxy_tags | index($tag));
        def generated_rule:
            .type == "field" and .outboundTag == "direct" and
            ((.inboundTag // []) | sort) == proxy_tags and
            .source == ["127.0.0.1"] and
            (keys | sort) == ["inboundTag", "outboundTag", "source", "type"];
        if ([.inbounds[] | select(.tag == "http-proxy" and .protocol == "http")] | length) != 1 or
           ([.inbounds[] | select(.tag == "socks5-proxy" and .protocol == "socks")] | length) != 1
        then error("require one HTTP and one SOCKS proxy inbound") else . end |
        if any(.routing.rules[]?; proxy_rule and has("source") and (generated_rule | not))
        then error("ambiguous custom proxy source restriction") else . end |
        (.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy")) |=
            (.listen = "127.0.0.1" |
             .port = (if .tag == "http-proxy" then 18118 else 10800 end) |
             .streamSettings.sockopt.acceptProxyProtocol = true) |
        if .routing.rules then
            .routing.rules |= map(if generated_rule then del(.source) else . end)
        else . end
    ' "$current" > "$staged" 2>/dev/null; then
        rm -f "$staged"
        echo 'Proxy staging failed: invalid inbounds or ambiguous custom proxy source restriction' >&2
        return 1
    fi
    cat "$staged" > "$output" || { rm -f "$staged"; return 1; }
    rm -f "$staged"
}

proxy_auth_ports() {
    case "$1" in
        true) printf '%s\n' '1080,1081,8118,8119' ;;
        false) printf '%s\n' '1080,8118' ;;
        *) return 1 ;;
    esac
}

# Own only exact project-generated global proxy rules. Preflight every port first.
_proxy_firewall_changes() {
    local ports status_text port line normalized rule_port action direction origin comment
    ports=$(proxy_auth_ports "$1") || return 1
    status_text=$(LC_ALL=C ufw status numbered) || return 1
    [[ "$status_text" == *'Status: active'* ]] || { echo 'UFW must be active' >&2; return 1; }
    local -a changes=()
    local managed found
    for port in ${ports//,/ }; do
        managed=false found=false
        while IFS= read -r line; do
            [[ "$line" =~ (^|[^0-9])${port}([^0-9]|$) ]] || continue
            normalized=$(printf '%s\n' "$line" | sed -E 's/^\[[[:space:]]*[0-9]+\][[:space:]]*//; s/ \(v6\)//g')
            read -r rule_port action direction origin comment <<< "$normalized"
            if [[ "$rule_port" != "$port/tcp" || "$direction" != IN || "$origin" != Anywhere ||
                  ( "$action" != ALLOW && "$action" != LIMIT ) ]]; then
                echo "Conflicting UFW rule for proxy port $port; preserve operator policy" >&2
                return 1
            fi
            case "$comment" in
                '# FamilyTraffic proxy auth'|'# VLESS SOCKS5 Proxy (rate-limited)'|'# VLESS HTTP Proxy (rate-limited)'|'# VLESS SOCKS5 Proxy no-TLS (rate-limited)'|'# VLESS HTTP Proxy no-TLS (rate-limited)') ;;
                *) echo "Unrecognized UFW rule for proxy port $port" >&2; return 1 ;;
            esac
            found=true
            [[ "$action" == LIMIT ]] && managed=true
        done <<< "$status_text"
        if [[ "$found" == false || "$managed" == true ]]; then changes+=("$port"); fi
    done
    if ((${#changes[@]})); then printf '%s\n' "${changes[@]}"; fi
}

validate_proxy_firewall() {
    _proxy_firewall_changes "$1" >/dev/null
}

reconcile_proxy_firewall() {
    local changes port
    changes=$(_proxy_firewall_changes "$1") || return 1
    [[ -n "$changes" ]] || return 0
    while IFS= read -r port; do
        # UFW replaces an exact global LIMIT match with ALLOW for IPv4 and IPv6.
        ufw allow "$port/tcp" comment 'FamilyTraffic proxy auth' || return 1
    done <<< "$changes"
    ufw reload || return 1
}
