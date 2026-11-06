#!/usr/bin/env bats
setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/traffic_monitoring.sh"
    input="$BATS_TEST_TMPDIR/input.json"
    output="$BATS_TEST_TMPDIR/output.json"
    printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[{"tag":"http-proxy","listen":"127.0.0.1","port":18118,"protocol":"http","settings":{"userLevel":2,"accounts":[{"user":"alice","pass":"secret"}]}}],"routing":{"rules":[{"type":"field","domain":["example.com"],"outboundTag":"direct"}]}}' > "$input"
}
@test "native monitoring preserves accounts and listeners and enables all configured levels" {
    FT_TRAFFIC_MONITORING=true stage_traffic_monitoring_config "$input" "$output"
    jq -e '.api.services == ["StatsService"] and .policy.levels["2"].statsUserUplink and .policy.levels["0"].statsUserDownlink and .routing.rules[0].outboundTag == "traffic-api" and .log.loglevel == "warning"' "$output"
    diff <(jq '.inbounds[0]' "$input") <(jq '.inbounds[0]' "$output")
    FT_TRAFFIC_MONITORING=true stage_traffic_monitoring_config "$output" "$BATS_TEST_TMPDIR/repeated"
    cmp "$output" "$BATS_TEST_TMPDIR/repeated"
}
@test "disabled monitoring copies configuration unchanged" {
    FT_TRAFFIC_MONITORING=false stage_traffic_monitoring_config "$input" "$output"
    cmp "$input" "$output"
}
@test "monitoring rejects an existing unrelated API" {
    jq '.api={"tag":"custom","services":["HandlerService"]}' "$input" > "$output"
    run env FT_TRAFFIC_MONITORING=true bash -c 'source "$1"; stage_traffic_monitoring_config "$2" "$3"' bash "$PROJECT_ROOT/lib/traffic_monitoring.sh" "$output" "$BATS_TEST_TMPDIR/rejected"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/rejected" ]
}
@test "identity map contains no passwords or UUIDs" {
    printf '%s\n' '{"users":[{"username":"alice","uuid":"private","proxy_password":"secret"}]}' > "$input"
    write_traffic_identity_map "$input" "$output"
    jq -e '.alice.user_id == "alice" and .["alice@vless.local"].account_class == "vless"' "$output"
    ! grep -E 'private|secret|password' "$output"
}
@test "nginx monitoring has minimal escaped stream log without debug" {
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    FT_TRAFFIC_MONITORING=true generate_nginx_config proxy.example.com false '' '' '' false true > "$output"
    grep -q 'log_format traffic escape=json' "$output"
    grep -q 'access_log /var/log/nginx/traffic.log traffic' "$output"
    ! grep -q 'loglevel.*debug' "$output"
}
@test "monitoring flag persists through generation without sourcing env text" {
    export VLESS_DIR="$BATS_TEST_TMPDIR"
    printf '%s\n' 'FT_TRAFFIC_MONITORING=true' 'OTHER=$(touch unsafe)' > "$VLESS_DIR/.env"
    unset FT_TRAFFIC_MONITORING
    stage_traffic_monitoring_config "$input" "$output"
    jq -e '.api.tag == "traffic-api"' "$output"
    printf '%s\n' 'FT_TRAFFIC_MONITORING=$(touch unsafe)' > "$VLESS_DIR/.env"
    run resolve_traffic_monitoring
    [ "$status" -ne 0 ]
    [ ! -e unsafe ]
}
