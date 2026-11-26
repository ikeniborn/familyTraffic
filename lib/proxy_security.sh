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

proxy_receiver_tags() {
    if [[ ${FT_SERVICE_MODE-} == vpn ]]; then
        echo '[]'
    elif [[ -z ${FT_SOCKS_TLS_PORT-1080}${FT_SOCKS_PLAIN_PORT-} ]]; then
        echo '["http-proxy"]'
    else
        echo '["http-proxy","socks5-proxy"]'
    fi
}

# Reject proxy listeners that could accept anonymous or empty credentials.
validate_proxy_auth_config() {
    if [[ -n ${FT_SERVICE_MODE:-} ]] && ! jq -e --argjson tags "$(proxy_receiver_tags)" '
        [.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy") | .tag] | sort == $tags
    ' "$1" >/dev/null; then
        echo 'Proxy receivers disagree with selected services' >&2
        return 1
    fi
    if ! jq -e '
        (.inbounds | type == "array") and
        ([.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy") |
            (((.tag == "http-proxy" and .protocol == "http") or
              (.tag == "socks5-proxy" and .protocol == "socks")) and
             (.settings.accounts | type == "array" and length > 0) and
             all(.settings.accounts[];
                 (.user | type == "string" and length > 0) and
                 (.pass | type == "string" and length > 0)) and
             (.protocol != "socks" or .settings.auth == "password"))] | all)
    ' "$1" >/dev/null 2>&1; then
        echo 'Proxy authentication preflight failed: require nonempty accounts and SOCKS password authentication' >&2
        return 1
    fi
    if jq -e 'any(.inbounds[] | .settings.accounts[]?; .user == "@ft-unprovisioned")' "$1" >/dev/null; then
        proxy_config_is_pending "$1" || { echo 'Invalid unprovisioned proxy lock' >&2; return 1; }
    fi
}

# Prepare selected proxy listeners without creating a user or permitting traffic.
# The private lock credential keeps HTTP authentication enabled with no saved users.
initialize_pending_proxy_config() {
    python3 - "$1" "$(proxy_receiver_tags)" <<'PY'
import json,pathlib,secrets,sys
path=pathlib.Path(sys.argv[1]);config=json.loads(path.read_text())
proxies=[i for i in config['inbounds'] if i['tag'] in ('http-proxy','socks5-proxy')]
tags=json.loads(sys.argv[2])
if not tags or sorted(i['tag'] for i in proxies)!=tags or any(i['settings'].get('accounts') for i in proxies):
    raise SystemExit('Only empty initial proxy receivers can be locked')
if not any(o.get('tag')=='blocked' and o.get('protocol')=='blackhole' for o in config['outbounds']):
    raise SystemExit('Missing blackhole outbound for unprovisioned proxies')
account={'user':'@ft-unprovisioned','pass':secrets.token_hex(32)}
for inbound in proxies:
    inbound['settings']['accounts']=[account]
rule={'type':'field','inboundTag':tags,'outboundTag':'blocked'}
config.setdefault('routing',{}).setdefault('rules',[]).insert(0,rule)
with path.open('w') as out:
    json.dump(config,out,indent=2);out.write('\n')
PY
}

proxy_config_is_pending() {
    jq -e --argjson tags "$(proxy_receiver_tags)" '
        [.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy")] as $proxies |
        ($tags != [] and ($proxies | map(.tag) | sort == $tags)) and
        (all($proxies[]; .settings.accounts == $proxies[0].settings.accounts)) and
        all($proxies[]; .settings.accounts | length == 1 and
            .[0].user == "@ft-unprovisioned" and (.[0].pass | test("^[a-f0-9]{64}$"))) and
        .routing.rules[0] == {type:"field",inboundTag:$tags,outboundTag:"blocked"} and
        any(.outbounds[]; .tag == "blocked" and .protocol == "blackhole")
    ' "$1" >/dev/null 2>&1
}

validate_saved_proxy_accounts() {
    if proxy_config_is_pending "$1"; then
        jq -e '[.users[] | select(.proxy_password != null and .proxy_password != "")] | length == 0' "$2" >/dev/null
        return $?
    fi
    jq -e --slurpfile users "$2" '
        ($users[0].users | map(select(.proxy_password != null and .proxy_password != "") |
            {user: .username, pass: .proxy_password}) | sort_by(.user)) as $accounts |
        ($accounts | length > 0) and
        all(.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy");
            (.settings.accounts | sort_by(.user)) == $accounts)
    ' "$1" >/dev/null
}

# Stage the private PROXY receivers without rebuilding users, transports, or routes.
stage_proxy_security_config() {
    local current="$1" output="$2" staged
    validate_proxy_auth_config "$current" || return 1
    staged=$(mktemp "${output}.tmp.XXXXXX") || return 1
    if ! jq -e --argjson tags "$(proxy_receiver_tags)" '
        def proxy_tags: $tags;
        def proxy_rule: (.inboundTag == null) or any(.inboundTag[]?; . as $tag | proxy_tags | index($tag));
        def managed_direct:
            .type == "field" and .outboundTag == "direct" and
            ((.inboundTag // []) | sort) == proxy_tags and
            (keys | sort) == ["inboundTag", "outboundTag", "source", "type"];
        if ([.inbounds[] | select(.tag == "http-proxy" and .protocol == "http")] | length) != 1 or
           ([.inbounds[] | select(.tag == "socks5-proxy" and .protocol == "socks")] | length) != (if ($tags | index("socks5-proxy")) == null then 0 else 1 end)
        then error("require one HTTP and one SOCKS proxy inbound") else . end |
        def managed_deny:
            . == {type:"field",inboundTag:$tags,outboundTag:"blocked"};
        (.routing.rules // []) as $rules |
        reduce range(0; $rules|length) as $i (.;
            $rules[$i] as $rule |
            if ($rule | proxy_rule and has("source")) then
                if ($rule | managed_direct) and ($rules[$i+1] | managed_deny) then .
                elif ($rule | managed_direct and .source == ["127.0.0.1"]) then del(.routing.rules[$i].source)
                else error("ambiguous custom proxy source restriction") end
            else . end) |
        (.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy")) |=
            (.listen = "127.0.0.1" |
             .port = (if .tag == "http-proxy" then 18118 else 10800 end) |
             .streamSettings.sockopt.acceptProxyProtocol = true)
    ' "$current" > "$staged" 2>/dev/null; then
        rm -f "$staged"
        echo 'Proxy staging failed: invalid inbounds or ambiguous custom proxy source restriction' >&2
        return 1
    fi
    (umask 077; cat "$staged" > "$output") || { rm -f "$staged"; return 1; }
    rm -f "$staged"
}

proxy_auth_ports() {
    if [[ -n ${FT_SERVICE_MODE:-} ]]; then
        local -a ports=()
        local port
        for port in "${FT_SOCKS_TLS_PORT-}" "${FT_SOCKS_PLAIN_PORT-}" "${FT_HTTPS_PROXY_PORT-}" "${FT_HTTP_PLAIN_PORT-}"; do
            [[ -z $port ]] || ports+=("$port")
        done
        local IFS=,
        printf '%s\n' "${ports[*]}"
        return
    fi
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
    local managed found portion overlaps
    local -a portions
    for port in ${ports//,/ }; do
        managed=false found=false
        while IFS= read -r line; do
            normalized=$(printf '%s\n' "$line" | sed -E 's/^\[[[:space:]]*[0-9]+\][[:space:]]*//; s/ \(v6\)//g')
            read -r rule_port action direction origin comment <<< "$normalized"
            [[ $rule_port != */udp ]] || continue
            overlaps=false
            IFS=, read -ra portions <<< "${rule_port%/*}"
            for portion in "${portions[@]}"; do
                if [[ $portion == "$port" ]]; then overlaps=true; break; fi
                if [[ $portion =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] &&
                   (( 10#${BASH_REMATCH[1]} <= port && port <= 10#${BASH_REMATCH[2]} )); then
                    overlaps=true
                    break
                fi
            done
            [[ $overlaps == true ]] || continue
            if [[ "$rule_port" != "$port/tcp" || "$direction" != IN || "$origin" != Anywhere ||
                  ( "$action" != ALLOW && "$action" != LIMIT ) ]]; then
                echo "Conflicting UFW rule for proxy port $port; preserve operator policy" >&2
                return 1
            fi
            case "$comment" in
                '# familyTraffic authenticated proxy')
                    [[ "$action" == ALLOW && ( "$port" == "${FT_SOCKS_TLS_PORT-1080}" || "$port" == "${FT_SOCKS_PLAIN_PORT-1081}" || "$port" == "${FT_HTTPS_PROXY_PORT-8118}" ) ]] || return 1 ;;
                '# familyTraffic HTTP proxy no-TLS')
                    [[ "$action" == ALLOW && "$port" == "${FT_HTTP_PLAIN_PORT-8119}" ]] || return 1 ;;
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
