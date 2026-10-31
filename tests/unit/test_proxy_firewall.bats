#!/usr/bin/env bats
setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    trace="$BATS_TEST_TMPDIR/trace"
    rules="$BATS_TEST_TMPDIR/rules"
    : > "$trace"
    : > "$rules"
    ufw() {
        case "$1" in
            status) printf 'Status: active\n'; cat "$rules" ;;
            allow)
                echo "$*" >> "$trace"
                local port="${2%/tcp}"
                sed -i "/^$port\/tcp /d" "$rules"
                printf '%s/tcp ALLOW IN Anywhere # FamilyTraffic proxy auth\n' "$port" >> "$rules"
                ;;
            reload) echo reload >> "$trace" ;;
            *) return 1 ;;
        esac
    }
}
@test "absent proxy rules become ALLOW and second run does not change rules" {
    reconcile_proxy_firewall false
    [ "$(grep -c '^allow' "$trace")" -eq 2 ]
    cp "$rules" "$BATS_TEST_TMPDIR/before"
    reconcile_proxy_firewall false
    [ "$(grep -c '^allow' "$trace")" -eq 2 ]
    cmp "$rules" "$BATS_TEST_TMPDIR/before"
    ! grep -q '1081\|8119' "$trace"
}
@test "managed LIMIT becomes ALLOW and no-TLS ports follow resolved mode" {
    echo '1080/tcp LIMIT IN Anywhere # VLESS SOCKS5 Proxy (rate-limited)' > "$rules"
    reconcile_proxy_firewall true
    ! grep -q LIMIT "$rules"
    grep -q '^allow 1081/tcp' "$trace"
    grep -q '^allow 8119/tcp' "$trace"
}
@test "custom source restriction is rejected before any mutation" {
    echo '8118/tcp ALLOW IN 192.0.2.10' > "$rules"
    run reconcile_proxy_firewall false
    [ "$status" -eq 1 ]
    [ ! -s "$trace" ]
}
@test "unrecognized global rule is rejected" {
    echo '1080/tcp LIMIT IN Anywhere # operator custom rule' > "$rules"
    run reconcile_proxy_firewall false
    [ "$status" -eq 1 ]
    [ ! -s "$trace" ]
}
@test "firewall preflight invokes no mutation" {
    validate_proxy_firewall true
    [ ! -s "$trace" ]
    [ ! -s "$rules" ]
}
