#!/usr/bin/env bats

setup() {
    root="$BATS_TEST_TMPDIR/deployment"
    mkdir -p "$root/config/nginx"
    source "$BATS_TEST_DIRNAME/../../lib/service_modes.sh"
}

proxy_settings() {
    cat > "$root/.env" <<'ENV'
FT_SERVICE_MODE=proxy
FT_VLESS_PUBLIC_PORT=
FT_HTTPS_PROXY_PORT=443
FT_SOCKS_TLS_PORT=
FT_HTTP_PLAIN_PORT=
FT_SOCKS_PLAIN_PORT=
ENV
}

@test "proxy-only settings preserve empty disabled endpoints" {
    proxy_settings
    load_service_settings "$root"
    [ "$FT_SERVICE_MODE:$FT_HTTPS_PROXY_PORT:$FT_SOCKS_TLS_PORT" = 'proxy:443:' ]
}

@test "partial and duplicate service selections are rejected" {
    proxy_settings
    sed -i '/FT_SOCKS_PLAIN_PORT/d' "$root/.env"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *FT_SOCKS_PLAIN_PORT* ]]
    proxy_settings
    echo 'FT_HTTPS_PROXY_PORT=442' >> "$root/.env"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *FT_HTTPS_PROXY_PORT* ]]
}

@test "duplicate or invalid ports fail before rendering" {
    proxy_settings
    load_service_settings "$root"
    for port in 443 65536 0 '10+1'; do
        FT_SOCKS_TLS_PORT="$port"
        run validate_service_settings
        [ "$status" -ne 0 ]
    done
}

@test "legacy managed settings resolve only the active protocol endpoints" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    generate_nginx_config example.test > "$root/config/nginx/nginx.conf"
    echo 'ENABLE_PUBLIC_PROXY=false' > "$root/.env"
    echo '{"inbounds":[{"tag":"vless-reality","protocol":"vless","port":8443}]}' > "$root/config/xray_config.json"
    load_service_settings "$root"
    [ "$FT_SERVICE_MODE:$FT_VLESS_PUBLIC_PORT:$FT_HTTPS_PROXY_PORT" = 'vpn:443:' ]
    sed -i 's/false/true/' "$root/.env"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *xray_config.json* ]]
}

@test "fresh proxy mode prompts only for selected public endpoints" {
    source "$BATS_TEST_DIRNAME/../../lib/interactive_params.sh"
    select_service_mode <<< $'2\n9440\nn\nn'
    [ "$FT_SERVICE_MODE:$FT_HTTPS_PROXY_PORT:$FT_SOCKS_TLS_PORT" = 'proxy:9440:' ]
}

@test "renderer emits one proxy port without Reality or SOCKS" {
    proxy_settings
    load_service_settings "$root"
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    run generate_nginx_config example.test
    [ "$status" -eq 0 ]
    [[ "$output" == *'listen 443 ssl;'* ]]
    [[ "$output" != *'listen 1080 ssl;'* && "$output" != *'ssl_preread on;'* ]]
}

@test "one selected receiver locks, validates and refuses a second unselected receiver" {
    proxy_settings
    load_service_settings "$root"
    source "$BATS_TEST_DIRNAME/../../lib/proxy_security.sh"
    config="$root/xray.json"
    echo '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}],"outbounds":[{"tag":"blocked","protocol":"blackhole"}]}' > "$config"
    initialize_pending_proxy_config "$config"
    proxy_config_is_pending "$config"
    validate_proxy_auth_config "$config"
    jq '.inbounds += [.inbounds[0]]' "$config" > "$root/invalid.json"
    run validate_proxy_auth_config "$root/invalid.json"
    [ "$status" -ne 0 ]
}

@test "proxy-only firewall and fail2ban share the actual port list" {
    proxy_settings
    load_service_settings "$root"
    source "$BATS_TEST_DIRNAME/../../lib/proxy_security.sh"
    source "$BATS_TEST_DIRNAME/../../lib/fail2ban_setup.sh"
    [ "$(proxy_auth_ports false)" = 443 ]
    _proxy_auth_port_set 443
    ! _proxy_auth_port_set 8118
}

@test "HTTPS-only export uses selected port and omits SOCKS files" {
    proxy_settings
    echo 'ENABLE_PUBLIC_PROXY=true' >> "$root/.env"
    echo 'DOMAIN=service.test' >> "$root/.env"
    load_service_settings "$root"
    export VLESS_HOME="$root" ENV_FILE="$root/.env" CLIENTS_DIR="$root/clients"
    export USERS_JSON="$root/users.json"
    source "$BATS_TEST_DIRNAME/../../lib/user_management.sh"
    echo '{"users":[{"username":"alice","connection_type":"proxy","proxy_password":"fixture-password"}]}' > "$USERS_JSON"
    get_server_ip() { echo 192.0.2.1; }
    for command in get_user_info show_proxy_credentials; do
        run "$command" alice
        [ "$status" -eq 0 ]
        [[ "$output" == *'https://alice:fixture-password@service.test:443'* ]]
    done
    export_all_proxy_configs alice fixture-password
    [ "$(cat "$CLIENTS_DIR/alice/http_config.txt")" = 'https://alice:fixture-password@service.test:443' ]
    grep -Fq 'https://alice:fixture-password@service.test:443' "$CLIENTS_DIR/alice/git_config.txt"
    [ "$(FT_HTTPS_PROXY_PORT=9443 proxy_client_address http)" = https://service.test:9443 ]
    [ "$(FT_HTTPS_PROXY_PORT='' FT_HTTP_PLAIN_PORT=443 proxy_client_address http)" = http://service.test:443 ]
    [ "$(FT_SOCKS_TLS_PORT=443 proxy_client_address socks5)" = socks5s://service.test:443 ]
    [ ! -e "$CLIENTS_DIR/alice/socks5_config.txt" ]
    ! grep -qi socks5 "$CLIENTS_DIR/alice/git_config.txt"
}

@test "fresh HTTPS-only Xray configuration requires no Reality inputs" {
    proxy_settings
    load_service_settings "$root"
    export XRAY_CONFIG="$root/config/xray_config.json" USERS_JSON="$root/users.json"
    echo '{"users":[]}' > "$USERS_JSON"
    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
    REALITY_DEST= REALITY_DEST_PORT= VLESS_PORT=
    create_xray_config true
    jq -e '[.inbounds[].tag] == ["http-proxy"]' "$XRAY_CONFIG"
    proxy_config_is_pending "$XRAY_CONFIG"
}

@test "legacy proxy with no VLESS receiver keeps its active endpoints" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    generate_nginx_config example.test > "$root/config/nginx/nginx.conf"
    printf 'DOMAIN=example.test\nPROXY_NOTLS_ENABLED=false\n' > "$root/.env"
    echo '{"inbounds":[{"tag":"http-proxy","protocol":"http","port":18118},{"tag":"socks5-proxy","protocol":"socks","port":10800}]}' > "$root/config/xray_config.json"
    load_service_settings "$root"
    [ "$FT_SERVICE_MODE:$FT_VLESS_PUBLIC_PORT:$FT_HTTPS_PROXY_PORT:$FT_SOCKS_TLS_PORT" = 'proxy::8118:1080' ]
    sed -i 's/127.0.0.1:18118;/127.0.0.1:29999;/' "$root/config/nginx/nginx.conf"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
}

@test "explicit disabled user type is rejected before schema migration" {
    proxy_settings
    load_service_settings "$root"
    source "$BATS_TEST_DIRNAME/../../lib/user_management.sh"
    migrate_users_schema_v525() { touch "$root/migrated"; return 1; }
    run create_user test-person vpn </dev/null
    [ "$status" -ne 0 ]
    [ ! -e "$root/migrated" ]
}

@test "reserved and occupied IPv6 ports fail preflight" {
    source "$BATS_TEST_DIRNAME/../../lib/interactive_params.sh"
    select_service_mode <<< $'2\n8440\nn\nn'
    ss() { printf 'LISTEN 0 10 [::]:8440 [::]:*\n'; }
    run check_selected_ports
    [ "$status" -ne 0 ]
    FT_HTTPS_PROXY_PORT=8022 SSH_CONNECTION='192.0.2.1 99 192.0.2.2 8022'
    run check_selected_ports
    [ "$status" -ne 0 ]
}

@test "plaintext toggle adds only the selected protocol and preserves custom TLS port" {
    proxy_settings
    load_service_settings "$root"
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    source "$BATS_TEST_DIRNAME/../../scripts/familytraffic-security"
    generate_nginx_config example.test > "$root/before"
    security_select_plaintext true
    [ "$FT_HTTP_PLAIN_PORT:$FT_SOCKS_PLAIN_PORT" = '8119:' ]
    security_stage_nginx "$root/before" "$root/after" true
    grep -q 'listen 443 ssl;' "$root/after"
    grep -q 'listen 8119;' "$root/after"
    ! grep -q 'listen 1081;' "$root/after"
    security_select_plaintext false
    security_stage_nginx "$root/after" "$root/disabled" false
    ! grep -q 'listen 8119;' "$root/disabled"
}

@test "first proxy user's failed activation restores the pending receiver and database" {
    proxy_settings
    load_service_settings "$root"
    export XRAY_CONFIG="$root/xray.json" USERS_JSON="$root/users.json" LOCK_FILE="$root/users.lock"
    export CLIENTS_DIR="$root/clients" ENV_FILE="$root/.env"
    source "$BATS_TEST_DIRNAME/../../lib/user_management.sh"
    printf '{"users":[]}\n' > "$USERS_JSON"
    printf '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}],"outbounds":[{"tag":"blocked","protocol":"blackhole"}]}\n' > "$XRAY_CONFIG"
    initialize_pending_proxy_config "$XRAY_CONFIG"
    cp "$XRAY_CONFIG" "$root/before"
    reload_xray() { proxy_config_is_pending "$XRAY_CONFIG"; }
    run create_user trial-user proxy </dev/null
    [ "$status" -ne 0 ]
    cmp "$XRAY_CONFIG" "$root/before"
    jq -e '.users == []' "$USERS_JSON"
}

@test "updating the source allowlist keeps the first-user lock and other routes" {
    proxy_settings
    load_service_settings "$root"
    export XRAY_CONFIG="$root/xray.json"
    source "$BATS_TEST_DIRNAME/../../lib/proxy_security.sh"
    echo '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}],"outbounds":[{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","inboundTag":["traffic-api"],"outboundTag":"traffic-api"}]}}' > "$XRAY_CONFIG"
    initialize_pending_proxy_config "$XRAY_CONFIG"
    PROXY_IPS_FILE="$root/ips.json"
    echo '{"allowed_ips":["192.0.2.10"]}' > "$PROXY_IPS_FILE"
    source "$BATS_TEST_DIRNAME/../../lib/proxy_whitelist.sh"
    regenerate_proxy_routing
    stage_proxy_security_config "$XRAY_CONFIG" "$root/staged.json"
    jq -e 'any(.routing.rules[]; .source == ["192.0.2.10"] and .outboundTag == "direct")' "$root/staged.json"
    proxy_config_is_pending "$XRAY_CONFIG"
    jq -e 'any(.routing.rules[]; .outboundTag=="traffic-api") and any(.routing.rules[]; .source==["192.0.2.10"] and .inboundTag==["http-proxy"])' "$XRAY_CONFIG"
}

@test "legacy plaintext-only listeners regenerate without a certificate" {
    export FT_SERVICE_MODE=proxy FT_VLESS_PUBLIC_PORT= FT_HTTPS_PROXY_PORT= FT_SOCKS_TLS_PORT=
    export FT_HTTP_PLAIN_PORT=8118 FT_SOCKS_PLAIN_PORT=1080 FT_LEGACY_SERVICE_SETTINGS=true
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    run generate_nginx_config ''
    [ "$status" -eq 0 ]
    [[ "$output" == *'listen 8118;'* && "$output" != *'ssl_certificate '* ]]
}

@test "legacy resolver refuses an additional custom stream backend" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    generate_nginx_config example.test | sed '/^stream {/a\    server { listen 9090; proxy_pass 127.0.0.1:9999; }' > "$root/config/nginx/nginx.conf"
    echo 'ENABLE_PUBLIC_PROXY=false' > "$root/.env"
    echo '{"inbounds":[{"tag":"vless-reality","protocol":"vless","port":8443}]}' > "$root/config/xray_config.json"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *nginx.conf* ]]
}

@test "canonical settings reject conflicting compatibility flags" {
    proxy_settings
    echo ENABLE_PUBLIC_PROXY=false >> "$root/.env"
    run load_service_settings "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *ENABLE_PUBLIC_PROXY* ]]
}

@test "legacy image health checks the active custom proxies and both backends" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    generate_nginx_config example.test | sed 's/listen 8118 ssl/listen 15118 ssl/' > "$root/config/nginx/nginx.conf"
    echo '{"inbounds":[{"tag":"http-proxy","protocol":"http","port":18118},{"tag":"socks5-proxy","protocol":"socks","port":10800}]}' > "$root/config/xray_config.json"
    run python3 "$SERVICE_SETTINGS_READER" --legacy-health "$root/config/xray_config.json" "$root/config/nginx/nginx.conf"
    [ "$status" -eq 0 ]
    [ "$(sort -n <<< "$output" | xargs)" = '1080 10800 15118 18118' ]
}

@test "fresh VPN works while an independent HTTP service owns port 80" {
    source "$BATS_TEST_DIRNAME/../../lib/interactive_params.sh"
    select_service_mode <<< $'1\n'
    ss() { echo 'LISTEN 0 10 0.0.0.0:80 0.0.0.0:*'; }
    check_selected_ports
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    run generate_nginx_config ''
    [ "$status" -eq 0 ]
    [[ "$output" != *'listen 80 '* ]]
}

@test "combined browser route preserves Reality and refuses an overlapping server name" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    export FT_SERVICE_MODE=both FT_VLESS_PUBLIC_PORT=443 FT_HTTPS_PROXY_PORT=8118
    export XRAY_CONFIG="$root/config/xray_config.json"
    echo '{"inbounds":[{"tag":"vless-reality","streamSettings":{"realitySettings":{"serverNames":["vpn.test","Alt.test"]}}}]}' > "$XRAY_CONFIG"
    run generate_nginx_config service.test
    [ "$status" = 0 ]
    [[ $output == *'service.test unix:/run/familytraffic-landing.sock;'* ]]
    [[ $output == *'default             127.0.0.1:8443;'* ]]
    run generate_nginx_config alt.test
    [ "$status" != 0 ]
    [[ $output == *'alt.test'* ]]
    run generate_nginx_config service.test true service.test
    [ "$status" != 0 ]
}

@test "transport collision and rejected restart preserve the installed combined configuration" {
    export VLESS_HOME="$root" VLESS_DIR="$root" XRAY_CONFIG="$root/config/xray_config.json" LOCK_FILE="$root/users.lock"
    mkdir -p "$root/data"
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
    source "$BATS_TEST_DIRNAME/../../lib/transport_manager.sh"
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    proxy_settings
    sed -i 's/=proxy$/=both/;s/FT_VLESS_PUBLIC_PORT=$/FT_VLESS_PUBLIC_PORT=443/;s/FT_HTTPS_PROXY_PORT=443/FT_HTTPS_PROXY_PORT=8118/' "$root/.env"
    echo DOMAIN=service.test >> "$root/.env"
    echo '{"inbounds":[{"tag":"vless-reality","streamSettings":{"realitySettings":{"serverNames":["vpn.test"]}}}]}' > "$XRAY_CONFIG"
    load_service_settings "$root"
    generate_nginx_config service.test > "$root/config/nginx/nginx.conf"
    local before
    before=$(sha256sum "$XRAY_CONFIG" "$root/config/nginx/nginx.conf")
    log_info() { :; }
    log_error() { echo "$*"; }
    log_success() { :; }
    log_warning() { :; }
    docker() {
        case "$1" in
            inspect) echo fixture-image ;;
            restart) if [[ ! -e $root/restart ]]; then touch "$root/restart"; return 1; fi ;;
            *) return 0 ;;
        esac
    }
    chmod 644 "$XRAY_CONFIG"
    run add_transport ws SERVICE.test
    [ "$status" != 0 ]
    [[ "$output" == *conflict* ]]
    [ ! -e "$TRANSPORTS_JSON" ]
    [ ! -e "$root/restart" ]
    run add_transport ws ws.service.test
    [ "$status" != 0 ]
    [ -e "$root/restart" ]
    [ "$(stat -c %a "$XRAY_CONFIG")" = 600 ]
    [ ! -e "$TRANSPORTS_JSON" ]
    [ "$(sha256sum "$XRAY_CONFIG" "$root/config/nginx/nginx.conf")" = "$before" ]
    chmod 644 "$XRAY_CONFIG"
    add_transport ws ws.service.test
    [ "$(stat -c %a "$XRAY_CONFIG")" = 600 ]
    grep -q ws.service.test "$root/config/nginx/nginx.conf"
    remove_transport ws
    [ "$(cat "$TRANSPORTS_JSON" | jq '.transports | length')" = 0 ]
    grep -q familytraffic-landing.sock "$root/config/nginx/nginx.conf"
}

@test "legacy combined staging is idempotent and rejects an ambiguous active VPN name" {
    source "$BATS_TEST_DIRNAME/../../lib/nginx_stream_generator.sh"
    source "$BATS_TEST_DIRNAME/../../scripts/familytraffic-security"
    SECURITY_LIB="$BATS_TEST_DIRNAME/../../lib"
    SECURITY_ROOT="$root" SECURITY_XRAY="$root/config/xray_config.json"
    echo DOMAIN=Service.test > "$root/.env"
    echo '{"inbounds":[{"tag":"vless-reality","protocol":"vless","port":8443,"streamSettings":{"realitySettings":{"serverNames":["vpn.test"]}}},{"tag":"http-proxy","protocol":"http","port":18118},{"tag":"socks5-proxy","protocol":"socks","port":10800}]}' > "$SECURITY_XRAY"
    generate_nginx_config Service.test > "$root/config/nginx/nginx.conf"
    load_service_settings "$root"
    [ "$FT_LEGACY_SERVICE_SETTINGS" = true ]
    security_stage_nginx "$root/config/nginx/nginx.conf" "$root/staged" false
    grep -q '/live/Service.test/fullchain.pem' "$root/staged"
    security_stage_nginx "$root/staged" "$root/again" false
    cmp "$root/staged" "$root/again"
    sed -i 's/vpn.test/service.test/' "$SECURITY_XRAY"
    run security_stage_nginx "$root/config/nginx/nginx.conf" "$root/rejected" false
    [ "$status" != 0 ]
    [ ! -e "$root/rejected" ]
    ! grep -q familytraffic-landing.sock "$root/config/nginx/nginx.conf"
}
