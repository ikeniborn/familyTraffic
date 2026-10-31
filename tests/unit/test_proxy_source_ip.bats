#!/usr/bin/env bats
setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    config="$BATS_TEST_TMPDIR/current.json"
    staged="$BATS_TEST_TMPDIR/staged.json"
    cat > "$config" <<'JSON'
{"inbounds":[{"tag":"socks5-proxy","protocol":"socks","listen":"0.0.0.0","port":10800,"settings":{"auth":"password","accounts":[{"user":"fixture","pass":"fixture"}]},"streamSettings":{"network":"tcp"}},{"tag":"http-proxy","protocol":"http","listen":"0.0.0.0","port":18118,"settings":{"accounts":[{"user":"fixture","pass":"fixture"}]}},{"tag":"ws","protocol":"vless","settings":{"clients":[{"id":"fixture-uuid"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/custom"}}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"external-proxy-user","protocol":"socks","settings":{"servers":[{"address":"upstream.example.com","port":443}]}}],"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","user":["fixture"],"outboundTag":"external-proxy-user"},{"type":"field","inboundTag":["socks5-proxy","http-proxy"],"source":["127.0.0.1"],"outboundTag":"direct"},{"type":"field","domain":["example.com"],"outboundTag":"direct"}]}}
JSON
}

@test "four proxy stream servers forward addresses without trusting public metadata" {
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    generate_nginx_config proxy.example.com false '' '' '' false true > "$BATS_TEST_TMPDIR/nginx.conf"
    [ "$(grep -c 'proxy_protocol on;' "$BATS_TEST_TMPDIR/nginx.conf")" -eq 4 ]
    ! grep -E 'listen .*proxy_protocol' "$BATS_TEST_TMPDIR/nginx.conf"
    sed -n '/listen 443;/,/^    }/p' "$BATS_TEST_TMPDIR/nginx.conf" > "$BATS_TEST_TMPDIR/reality"
    ! grep proxy_protocol "$BATS_TEST_TMPDIR/reality"
}

@test "staging updates private receivers and only generated source rule" {
    stage_proxy_security_config "$config" "$staged"
    jq -e '[.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy") | .listen == "127.0.0.1" and .streamSettings.sockopt.acceptProxyProtocol == true] | all' "$staged"
    jq -e '.routing.rules[1] | has("source") | not' "$staged"
    jq '{outbounds, unrelated: .inbounds[2], first: .routing.rules[0], last: .routing.rules[2]}' "$config" > "$BATS_TEST_TMPDIR/before"
    jq '{outbounds, unrelated: .inbounds[2], first: .routing.rules[0], last: .routing.rules[2]}' "$staged" > "$BATS_TEST_TMPDIR/after"
    cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
    stage_proxy_security_config "$staged" "$BATS_TEST_TMPDIR/repeat.json"
    cmp "$staged" "$BATS_TEST_TMPDIR/repeat.json"
}

@test "ambiguous custom source condition fails without replacing output or input" {
    jq '.routing.rules[1].source = ["192.0.2.10"]' "$config" > "$BATS_TEST_TMPDIR/custom.json"
    printf preserved > "$staged"
    run stage_proxy_security_config "$BATS_TEST_TMPDIR/custom.json" "$staged"
    [ "$status" -eq 1 ]
    [ "$(cat "$staged")" = preserved ]
    jq -e '.routing.rules[1].source == ["192.0.2.10"]' "$BATS_TEST_TMPDIR/custom.json"
}

@test "global source restriction also requires explicit migration review" {
    jq 'del(.routing.rules[1].inboundTag)' "$config" > "$BATS_TEST_TMPDIR/global.json"
    run stage_proxy_security_config "$BATS_TEST_TMPDIR/global.json" "$staged"
    [ "$status" -eq 1 ]
}
