#!/usr/bin/env bats
setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    config="$BATS_TEST_TMPDIR/config.json"
}

@test "empty HTTP accounts fail public preflight" {
    printf '%s\n' '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}]}' > "$config"
    run validate_proxy_auth_config "$config"
    [ "$status" -eq 1 ]
}

@test "SOCKS noauth and blank credentials fail public preflight" {
    for settings in '{"auth":"noauth","accounts":[{"user":"fixture","pass":"fixture"}]}' '{"auth":"password","accounts":[{"user":"fixture","pass":""}]}'; do
        printf '{"inbounds":[{"tag":"socks5-proxy","protocol":"socks","settings":%s}]}' "$settings" > "$config"
        run validate_proxy_auth_config "$config"
        [ "$status" -eq 1 ]
    done
}

@test "authenticated proxies pass and unrelated inbounds remain valid" {
    printf '%s\n' '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[{"user":"fixture","pass":"fixture"}]}},{"tag":"socks5-proxy","protocol":"socks","settings":{"auth":"password","accounts":[{"user":"fixture","pass":"fixture"}]}},{"tag":"reality","protocol":"vless"}]}' > "$config"
    run validate_proxy_auth_config "$config"
    [ "$status" -eq 0 ]
}

@test "failed account synchronization preserves current configuration" {
    source "$PROJECT_ROOT/lib/common.sh"
    source <(sed -n '/^rebuild_proxy_accounts_from_users_json()/,/^}/p' "$PROJECT_ROOT/lib/user_management.sh")
    XRAY_CONFIG="$config" USERS_JSON="$BATS_TEST_TMPDIR/users.json"
    printf '%s\n' '{"inbounds":[{"tag":"socks5-proxy","protocol":"socks","settings":{"auth":"password","accounts":[{"user":"existing","pass":"existing"}]}},{"tag":"http-proxy","protocol":"http","settings":{"accounts":[{"user":"existing","pass":"existing"}]}}]}' > "$config"
    cp "$config" "$BATS_TEST_TMPDIR/before"
    log_info() { :; }
    log_error() { :; }
    log_success() { :; }
    for users in 'invalid-json' '{"users":[]}'; do
        printf '%s\n' "$users" > "$USERS_JSON"
        run rebuild_proxy_accounts_from_users_json
        [ "$status" -eq 1 ]
        cmp "$config" "$BATS_TEST_TMPDIR/before"
    done
}

@test "empty accounts prevent container activation before Docker invocation" {
    source <(sed -n '/^deploy_containers()/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    XRAY_CONFIG="$config"
    printf '%s\n' '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}]}' > "$config"
    docker() { touch "$BATS_TEST_TMPDIR/docker-called"; }
    run deploy_containers
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/docker-called" ]
}

@test "generated proxy receivers enable PROXY only on loopback" {
    source <(sed -n '/^generate_socks5_inbound_json()/,/^}/p; /^generate_http_inbound_json()/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    printf '{"inbounds":[{"tag":"reality"}' > "$config"
    generate_socks5_inbound_json >> "$config"
    generate_http_inbound_json >> "$config"
    printf ']}' >> "$config"
    jq -e '[.inbounds[] | select(.tag != "reality") | .listen == "127.0.0.1" and .streamSettings.sockopt.acceptProxyProtocol == true] | length == 2 and all' "$config"
}

@test "private custom unauthenticated receiver is outside generated public proxy guard" {
    printf '%s\n' '{"inbounds":[{"tag":"custom-private-http","listen":"127.0.0.1","port":18119,"protocol":"http","settings":{"accounts":[]}}]}' > "$config"
    run validate_proxy_auth_config "$config"
    [ "$status" -eq 0 ]
}
