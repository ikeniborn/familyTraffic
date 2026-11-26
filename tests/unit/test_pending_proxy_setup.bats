#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    export XRAY_CONFIG="$BATS_TEST_TMPDIR/xray.json" USERS_JSON="$BATS_TEST_TMPDIR/users.json"
    cat > "$XRAY_CONFIG" <<'JSON'
{"inbounds":[{"tag":"socks5-proxy","protocol":"socks","settings":{"auth":"password","accounts":[]}},{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","domain":["example.com"],"outboundTag":"direct"}]}}
JSON
    printf '{"users":[]}' > "$USERS_JSON"
}

@test "unprovisioned proxies keep authenticated receivers and deny all destinations" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    validate_proxy_auth_config "$XRAY_CONFIG"
    proxy_config_is_pending "$XRAY_CONFIG"
    jq -e '.routing.rules[0] == {type:"field",inboundTag:["http-proxy","socks5-proxy"],outboundTag:"blocked"} and (.inbounds | all(.settings.accounts | length == 1)) and (.inbounds[0].settings.accounts == .inbounds[1].settings.accounts)' "$XRAY_CONFIG"
    [ "$(jq '.users|length' "$USERS_JSON")" -eq 0 ]
}

@test "first proxy user removes setup lock and receives access without reinstalling" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    source "$PROJECT_ROOT/lib/user_management.sh"
    log_info() { :; }; log_success() { :; }; log_error() { :; }
    chmod 644 "$XRAY_CONFIG"
    local inode
    inode=$(stat -c %i "$XRAY_CONFIG")
    update_proxy_accounts alice secret-for-test
    [ "$(stat -c %i "$XRAY_CONFIG")" = "$inode" ]
    [ "$(stat -c %a "$XRAY_CONFIG")" = 600 ]
    ! proxy_config_is_pending "$XRAY_CONFIG"
    jq -e 'all(.inbounds[]; .settings.accounts == [{user:"alice",pass:"secret-for-test"}]) and .routing.rules == [{type:"field",domain:["example.com"],outboundTag:"direct"}]' "$XRAY_CONFIG"
    validate_proxy_auth_config "$XRAY_CONFIG"
}

@test "non-proxy user synchronization keeps selected proxies locked" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    source "$PROJECT_ROOT/lib/user_management.sh"
    log_info() { :; }; log_success() { :; }; log_error() { :; }
    printf '{"users":[{"username":"vpn-only","uuid":"test-uuid"}]}' > "$USERS_JSON"
    rebuild_proxy_accounts_from_users_json
    proxy_config_is_pending "$XRAY_CONFIG"
    jq -e '.users[0] | has("proxy_password") | not' "$USERS_JSON"
}

@test "pending detector rejects an allow route ahead of setup lock" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    jq '.routing.rules |= ([{type:"field",inboundTag:["http-proxy"],outboundTag:"direct"}] + .)' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/unsafe.json"
    ! proxy_config_is_pending "$BATS_TEST_TMPDIR/unsafe.json"
}

@test "VPN routing updates preserve pending proxy lock" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    source "$PROJECT_ROOT/lib/user_management.sh"
    # Keep real routing writes; isolate only upstream routing discovery and reload.
    source() { :; }
    update_per_user_xray_outbounds() { :; }
    generate_per_user_routing_rules() { printf '%s' '{"rules":[{"type":"field","inboundTag":["vless-reality"],"outboundTag":"direct"}]}'; }
    reload_xray() { validate_proxy_auth_config "$XRAY_CONFIG"; }
    log_info() { :; }; log_success() { :; }; log_error() { :; }; log_warning() { :; }
    apply_per_user_routing
    proxy_config_is_pending "$XRAY_CONFIG"
    jq -e '.routing.rules[1:] | any(.inboundTag == ["vless-reality"]) and any(.domain == ["example.com"])' "$XRAY_CONFIG"
}

@test "installer generates selected proxy configuration without a saved user" {
    source "$PROJECT_ROOT/lib/common.sh"
    source "$PROJECT_ROOT/lib/orchestrator.sh"
    PRIVATE_KEY=fixture SHORT_ID=abcd REALITY_DEST=example.com REALITY_DEST_PORT=443 VLESS_PORT=8443
    DETECTED_DNS_PRIMARY='' DETECTED_DNS_SECONDARY='' DETECTED_DNS_TERTIARY='' ENABLE_PUBLIC_PROXY=true
    create_xray_config true
    validate_proxy_auth_config "$XRAY_CONFIG"
    validate_saved_proxy_accounts "$XRAY_CONFIG" "$USERS_JSON"
    proxy_config_is_pending "$XRAY_CONFIG"
    jq -e '.users == []' "$USERS_JSON"
}

@test "pending receivers cannot hide disagreement with a saved proxy user" {
    initialize_pending_proxy_config "$XRAY_CONFIG"
    printf '{"users":[{"username":"alice","proxy_password":"secret"}]}' > "$USERS_JSON"
    run validate_saved_proxy_accounts "$XRAY_CONFIG" "$USERS_JSON"
    [ "$status" -ne 0 ]
}

@test "vision migration keeps the active config and temporary credentials private" {
    source "$PROJECT_ROOT/lib/user_management.sh"
    jq '.inbounds[0].settings.clients = [{id:"fixture"}]' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/legacy"
    mv "$BATS_TEST_TMPDIR/legacy" "$XRAY_CONFIG"
    chmod 644 "$XRAY_CONFIG"
    umask 022
    docker() { return 0; }
    jq() {
        local file
        for file in "$XRAY_CONFIG".bak.* "$XRAY_CONFIG".tmp.*; do
            [[ ! -e $file || $(stat -c %a "$file") == 600 ]] || return 1
        done
        command jq "$@"
    }
    migrate_xtls_vision
    [ "$(stat -c %a "$XRAY_CONFIG")" = 600 ]
    jq -e '.inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' "$XRAY_CONFIG"
}
