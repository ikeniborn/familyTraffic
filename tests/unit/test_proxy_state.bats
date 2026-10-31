#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    state="$BATS_TEST_TMPDIR/state"
}

@test "first install honors explicit no-TLS without saved state" {
    run resolve_proxy_notls true "$state"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
}

@test "explicit false overrides saved true" {
    echo PROXY_NOTLS_ENABLED=true > "$state"
    run resolve_proxy_notls false "$state"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "absent selection reads saved true" {
    echo PROXY_NOTLS_ENABLED=true > "$state"
    run resolve_proxy_notls '' "$state"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
}

@test "absent selection and state default false" {
    run resolve_proxy_notls '' "$state"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "malformed conflicting and executable saved values fail without execution" {
    for value in 'true-extra' '$(touch forbidden)' '"true"' ''; do
        printf 'PROXY_NOTLS_ENABLED=%s\n' "$value" > "$state"
        run resolve_proxy_notls '' "$state"
        [ "$status" -eq 1 ]
    done
    printf 'PROXY_NOTLS_ENABLED=true\nPROXY_NOTLS_ENABLED=false\n' > "$state"
    run resolve_proxy_notls '' "$state"
    [ "$status" -eq 1 ]
}

@test "invalid explicit choice fails and unrelated shell text is not sourced" {
    printf 'echo unexpected\nOTHER=value\nPROXY_NOTLS_ENABLED=false\n' > "$state"
    run resolve_proxy_notls invalid "$state"
    [ "$status" -eq 1 ]
    run resolve_proxy_notls '' "$state"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "generator retains unrelated transports and honors repeated explicit choices" {
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    export VLESS_DIR="$BATS_TEST_TMPDIR"
    local mode
    for mode in true false true; do
        generate_nginx_config proxy.example.com true ws.example.com xhttp.example.com grpc.example.com true "$mode" > "$BATS_TEST_TMPDIR/$mode.conf"
        if [[ "$mode" = true ]]; then
            grep -q 'listen 1081;' "$BATS_TEST_TMPDIR/$mode.conf"
            grep -q 'listen 8119;' "$BATS_TEST_TMPDIR/$mode.conf"
        else
            ! grep -q 'listen 1081;' "$BATS_TEST_TMPDIR/$mode.conf"
            ! grep -q 'listen 8119;' "$BATS_TEST_TMPDIR/$mode.conf"
        fi
    done
    sed -n '/^http {/,$p' "$BATS_TEST_TMPDIR/true.conf" > "$BATS_TEST_TMPDIR/http-true"
    sed -n '/^http {/,$p' "$BATS_TEST_TMPDIR/false.conf" > "$BATS_TEST_TMPDIR/http-false"
    cmp "$BATS_TEST_TMPDIR/http-true" "$BATS_TEST_TMPDIR/http-false"
    grep -q ws.example.com "$BATS_TEST_TMPDIR/http-true"
    grep -q 'listen 4443 ssl;' "$BATS_TEST_TMPDIR/http-true"
}

@test "transport regeneration preserves inode state files and explicit false" {
    source "$PROJECT_ROOT/lib/common.sh"
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    source "$PROJECT_ROOT/lib/transport_manager.sh"
    export VLESS_DIR="$BATS_TEST_TMPDIR/install"
    export PROXY_NOTLS_ENABLED=false
    export CERT_DOMAIN=proxy.example.com
    mkdir -p "$VLESS_DIR/config/nginx" "$VLESS_DIR/data"
    TRANSPORTS_JSON="$VLESS_DIR/data/transports.json"
    printf '%s\n' '{"transports":[{"type":"ws","subdomain":"ws.example.com"}]}' > "$TRANSPORTS_JSON"
    generate_nginx_config proxy.example.com true ws.example.com '' '' true true > "$VLESS_DIR/config/nginx/nginx.conf"
    cp "$TRANSPORTS_JSON" "$BATS_TEST_TMPDIR/transports-before"
    local inode
    inode=$(stat -c %i "$VLESS_DIR/config/nginx/nginx.conf")
    log_info() { :; }
    log_success() { :; }
    log_error() { echo "$*" >&2; }
    _regenerate_nginx_config
    [ "$(stat -c %i "$VLESS_DIR/config/nginx/nginx.conf")" = "$inode" ]
    ! grep -q 'listen 1081;' "$VLESS_DIR/config/nginx/nginx.conf"
    grep -q ws.example.com "$VLESS_DIR/config/nginx/nginx.conf"
    cmp "$TRANSPORTS_JSON" "$BATS_TEST_TMPDIR/transports-before"
}

@test "installer wrapper retains first-install choice and exported mode" {
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    source <(sed -n '/^generate_nginx_config_wrapper()/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    export VLESS_DIR="$BATS_TEST_TMPDIR/install"
    export CERT_DOMAIN=proxy.example.com PROXY_NOTLS_ENABLED=true
    CYAN='' NC='' RED='' YELLOW='' GREEN=''
    generate_nginx_config_wrapper
    [ "$PROXY_NOTLS_ENABLED" = true ]
    grep -q 'listen 1081;' "$VLESS_DIR/config/nginx/nginx.conf"
    grep -q 'listen 8119;' "$VLESS_DIR/config/nginx/nginx.conf"
    generate_nginx_config_wrapper
    grep -q 'listen 1081;' "$VLESS_DIR/config/nginx/nginx.conf"
}
