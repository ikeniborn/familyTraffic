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
    configure_proxy_auth_jail 1080,8118
    fail2ban-client() {
        case "$*" in
            '-t') return 0 ;;
            '-d') printf '%s\n' "['add', 'familytraffic-proxy-auth', 'polling']" "['set', 'familytraffic-proxy-auth', 'addfailregex', '^ FT_AUTH_FAILURE protocol=(?:http|socks)']" ;;
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

@test "live regex comparison rejects an appended never-match suffix" {
    local dump="['set', 'familytraffic-proxy-auth', 'addfailregex', '^ FT_AUTH_FAILURE protocol=(?:http|socks) src=expected$']"
    run _proxy_auth_live_regex_matches "$dump" '[0]: ^ FT_AUTH_FAILURE protocol=(?:http|socks) src=expected$NEVERMATCH'
    [ "$status" -ne 0 ]
    run _proxy_auth_live_regex_matches "$dump" '[0]: ^ FT_AUTH_FAILURE protocol=(?:http|socks) src=expected$'
    [ "$status" -eq 0 ]
}

@test "UTC journal timestamps remain UTC on a non-UTC host and offsets are rejected" {
    configure_proxy_auth_jail 1080,8118
    run /usr/bin/python3 - "$FT_FAIL2BAN_DIR/filter.d/familytraffic-proxy-auth.conf" <<'PY'
import configparser,datetime,os,sys,time
from fail2ban.server.datetemplate import DatePatternRegex
os.environ['TZ']='Europe/Moscow';time.tzset()
config=configparser.ConfigParser();config.read(sys.argv[1])
pattern=DatePatternRegex(config.get('Definition','datepattern'))
line='2026-10-31T12:00:00Z FT_AUTH_FAILURE protocol=http src=192.0.2.10'
expected=datetime.datetime(2026,10,31,12,tzinfo=datetime.timezone.utc).timestamp()
assert pattern.getDate(line)[0]==expected
assert pattern.getDate(line.replace('Z ','+0300 ')) is None
PY
    [ "$status" -eq 0 ]
}

@test "live regex comparison expands fail2ban address tags before exact comparison" {
    local raw='^ FT_AUTH_FAILURE protocol=http src=<ADDR>$' expanded dump
    expanded=$(/usr/bin/python3 -c 'import sys;from fail2ban.server.failregex import Regex;print(Regex(sys.argv[1],useDns="no").getRegex())' "$raw")
    dump="['set', 'familytraffic-proxy-auth', 'addfailregex', '$raw']"
    run _proxy_auth_live_regex_matches "$dump" "[0]: $expanded"
    [ "$status" -eq 0 ]
}

@test "reviewed legacy v3.2 jail is retired but customized variant is rejected" {
    cp "$PROJECT_ROOT/tests/fixtures/legacy-vless-proxy.conf" "$FT_FAIL2BAN_DIR/jail.d/vless-proxy.conf"
    run configure_proxy_auth_jail 1080,8118
    [ "$status" -eq 0 ]
    [ -f "$FT_FAIL2BAN_DIR/jail.d/vless-proxy.conf.disabled" ]
    cp "$PROJECT_ROOT/tests/fixtures/legacy-vless-proxy.conf" "$FT_FAIL2BAN_DIR/jail.d/vless-proxy.conf"
    printf '\n# operator customization\n' >> "$FT_FAIL2BAN_DIR/jail.d/vless-proxy.conf"
    run configure_proxy_auth_jail 1080,8118
    [ "$status" -eq 1 ]
    [ -f "$FT_FAIL2BAN_DIR/jail.d/vless-proxy.conf" ]
}
