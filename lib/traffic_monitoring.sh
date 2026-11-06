#!/usr/bin/env bash
# Opt-in native statistics. No transfer-path changes are required.
resolve_traffic_monitoring() {
    local value="${FT_TRAFFIC_MONITORING-}" env_file="${VLESS_DIR:-/opt/familytraffic}/.env"
    if [[ -z "$value" && -f "$env_file" ]]; then
        value=$(sed -n 's/^FT_TRAFFIC_MONITORING=//p' "$env_file")
    fi
    value="${value:-false}"
    case "$value" in true|false) printf '%s\n' "$value" ;; *) echo 'Invalid FT_TRAFFIC_MONITORING value' >&2; return 1 ;; esac
}

stage_traffic_monitoring_config() {
    local input="$1" output="$2" staged enabled
    enabled=$(resolve_traffic_monitoring) || return 1
    if [[ "$enabled" != true ]]; then
        [[ "$input" == "$output" ]] || cp -- "$input" "$output"
        return 0
    fi
    if ! jq -e '(.api == null or .api == {"tag":"traffic-api","services":["StatsService"]}) and all(.inbounds[]; .tag == "traffic-api" or .port != 10085)' "$input" >/dev/null; then
        echo 'Traffic API conflicts with existing configuration' >&2
        return 1
    fi
    staged=$(mktemp "${output}.traffic.XXXXXX") || return 1
    if ! jq '
      .stats = {} |
      .api = {tag:"traffic-api",services:["StatsService"]} |
      .log.access = "/var/log/xray/access.log" |
      .log.loglevel = "warning" |
      ([0] + [.inbounds[].settings.userLevel // 0] + [.inbounds[].settings.clients[]?.level // 0] | unique) as $levels |
      reduce $levels[] as $level (.; .policy.levels[($level|tostring)].statsUserUplink = true | .policy.levels[($level|tostring)].statsUserDownlink = true) |
      .policy.system += {statsInboundUplink:true,statsInboundDownlink:true,statsOutboundUplink:true,statsOutboundDownlink:true} |
      .inbounds = ([.inbounds[] | select(.tag != "traffic-api")] + [{tag:"traffic-api",listen:"127.0.0.1",port:10085,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}]) |
      .routing.rules = ([{type:"field",inboundTag:["traffic-api"],outboundTag:"traffic-api"}] + [.routing.rules[]? | select(.inboundTag != ["traffic-api"])])
    ' "$input" > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    chmod 600 "$staged"
    mv -- "$staged" "$output"
}

write_traffic_identity_map() {
    local input="$1" output="$2" staged
    staged=$(mktemp "${output}.XXXXXX") || return 1
    if ! jq '[.users[] | select(.username | test("^[A-Za-z0-9_-]{3,32}$")) | {key:.username,value:{user_id:.username,account_class:"proxy"}}, {key:(.username+"@vless.local"),value:{user_id:.username,account_class:"vless"}}] | from_entries' "$input" > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    chmod 644 "$staged"
    mv -- "$staged" "$output"
}

refresh_traffic_identity_map() {
    local config="$1" output="$2" staged
    jq -e '.api.tag == "traffic-api"' "$config" >/dev/null || return 0
    staged=$(mktemp "${output}.XXXXXX") || return 1
    if ! jq '[.inbounds[] | (.settings.accounts[]? | {key:.user,value:{user_id:.user,account_class:"proxy"}}), (.settings.clients[]? | select(.email != null) | {key:.email,value:{user_id:(.email | sub("@vless.local$";"")),account_class:"vless"}})] | map(select(.value.user_id | test("^[A-Za-z0-9_-]{3,32}$"))) | from_entries' "$config" > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    chmod 644 "$staged"
    mv -- "$staged" "$output"
}
