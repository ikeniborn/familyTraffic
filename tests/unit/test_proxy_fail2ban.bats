#!/usr/bin/env bats
setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$PROJECT_ROOT/lib/fail2ban_setup.sh"
    export FT_FAIL2BAN_DIR="$BATS_TEST_TMPDIR/fail2ban" FT_LOGROTATE_DIR="$BATS_TEST_TMPDIR/logrotate"
    export FT_PROXY_AUTH_LOG="$BATS_TEST_TMPDIR/logs/auth.log"
    mkdir -p "$FT_FAIL2BAN_DIR/jail.d" "$(dirname "$FT_PROXY_AUTH_LOG")"
    touch "$FT_PROXY_AUTH_LOG"
    chmod 600 "$FT_PROXY_AUTH_LOG"
}
@test "managed auth jail uses file polling exact ports and thresholds" {
    configure_proxy_auth_jail 1080,1081,8118,8119
    grep -q '^backend = polling$' "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
    grep -q '^usedns = no$' "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
    grep -q '^maxretry = 5$' "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
    grep -q '^findtime = 600$' "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
    grep -q '^bantime = 3600$' "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
    cp "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf" "$BATS_TEST_TMPDIR/before"
    configure_proxy_auth_jail 1080,1081,8118,8119
    cmp "$BATS_TEST_TMPDIR/before" "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf"
}
@test "custom legacy jail is preserved and rejected" {
    echo '[vless-http]' > "$FT_FAIL2BAN_DIR/jail.d/vless-http.conf"
    run configure_proxy_auth_jail 1080,8118
    [ "$status" -eq 1 ]
    [ "$(cat "$FT_FAIL2BAN_DIR/jail.d/vless-http.conf")" = '[vless-http]' ]
}
@test "missing journal and unsupported port set fail" {
    rm "$FT_PROXY_AUTH_LOG"
    run configure_proxy_auth_jail 1080,8118
    [ "$status" -eq 1 ]
    touch "$FT_PROXY_AUTH_LOG"
    run configure_proxy_auth_jail 22,443,1080,8118
    [ "$status" -eq 1 ]
}
@test "strict filter matches captured events and rejects every negative" {
    configure_proxy_auth_jail 1080,8118
    run fail2ban-regex "$PROJECT_ROOT/tests/fixtures/proxy-auth-positive.log" "$FT_FAIL2BAN_DIR/filter.d/familytraffic-proxy-auth.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *'4) [1] '* ]] || [[ "$output" == *'4 matched'* ]]
    run fail2ban-regex "$PROJECT_ROOT/tests/fixtures/proxy-auth-negative.log" "$FT_FAIL2BAN_DIR/filter.d/familytraffic-proxy-auth.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *'0 matched'* ]]
}

@test "live verification rejects wrong monitoring thresholds and action ports" {
    fail2ban-client() {
        case "$*" in
            '-t') return 0 ;;
            '-d') echo "['add', 'familytraffic-proxy-auth', 'polling']" ;;
            'status familytraffic-proxy-auth') echo "File list: $FT_PROXY_AUTH_LOG" ;;
            'get familytraffic-proxy-auth maxretry') echo 5 ;;
            'get familytraffic-proxy-auth findtime') echo 600 ;;
            'get familytraffic-proxy-auth bantime') echo "${test_bantime:-3600}" ;;
            'get familytraffic-proxy-auth usedns') echo no ;;
            'get familytraffic-proxy-auth logpath') echo "$FT_PROXY_AUTH_LOG" ;;
            'get familytraffic-proxy-auth ignoreip') printf 'These IP addresses/networks are ignored:\n|- 127.0.0.0/8\n`- ::1\n' ;;
            'get familytraffic-proxy-auth failregex') echo '[0]: ^ FT_AUTH_FAILURE protocol=(?:http|socks)' ;;
            'get familytraffic-proxy-auth action iptables-multiport port') echo "${test_ports:-1080,8118}" ;;
            'get familytraffic-proxy-auth action iptables-multiport protocol') echo tcp ;;
            *) return 1 ;;
        esac
    }
    verify_proxy_auth_jail 1080,8118
    test_bantime=5
    run verify_proxy_auth_jail 1080,8118
    [ "$status" -eq 1 ]
    test_bantime=3600 test_ports=22,1080,8118
    run verify_proxy_auth_jail 1080,8118
    [ "$status" -eq 1 ]
}
@test "jail ownership preflight writes no policy" {
    validate_proxy_jail_ownership 1080,8118
    [ ! -e "$FT_FAIL2BAN_DIR/jail.d/familytraffic-proxy-auth.conf" ]
    [ ! -e "$FT_LOGROTATE_DIR/familytraffic-proxy-auth" ]
}
