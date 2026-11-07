#!/usr/bin/env bats
setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$ROOT/lib/installer_security.sh"
    export FT_FAIL2BAN_DIR="$BATS_TEST_TMPDIR/fail2ban"
    mkdir -p "$FT_FAIL2BAN_DIR/jail.d"
    printf '[DEFAULT]\nignoreip = 127.0.0.0/8 ::1\n[sshd]\nignoreip = 192.0.2.1\n[familytraffic-proxy-auth]\n' > "$FT_FAIL2BAN_DIR/jail.conf"
}
@test "allowlist extends both jails and survives empty and repeated input" {
    configure_fail2ban_allowlist '198.51.100.4 2001:db8::/64'
    cp "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local" "$BATS_TEST_TMPDIR/before"
    configure_fail2ban_allowlist ''
    configure_fail2ban_allowlist '198.51.100.4 2001:db8::/64'
    cmp "$BATS_TEST_TMPDIR/before" "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local"
    grep -q '192.0.2.1' "$BATS_TEST_TMPDIR/before"
    grep -q '127.0.0.0/8' "$BATS_TEST_TMPDIR/before"
    [ "$(grep -c '198.51.100.4' "$BATS_TEST_TMPDIR/before")" = 2 ]
}
@test "invalid allowlist cannot change configuration" {
    run configure_fail2ban_allowlist $'192.0.2.1\n[sshd]\nenabled=false'
    [ "$status" -ne 0 ]
    [ ! -e "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local" ]
}
@test "noninteractive input is validated" {
    export FT_FAIL2BAN_ALLOWLIST='192.0.2.5 ::1'
    prompt_fail2ban_allowlist
    [ "$FAIL2BAN_ALLOWLIST" = "$FT_FAIL2BAN_ALLOWLIST" ]
    export FT_FAIL2BAN_ALLOWLIST='invalid'
    run prompt_fail2ban_allowlist
    [ "$status" -ne 0 ]
}

@test "scoped IPv6 is rejected before persistence" {
    run configure_fail2ban_allowlist 'fe80::1%eth0'
    [ "$status" -ne 0 ]
    [ ! -e "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local" ]
}

@test "custom settings cannot be overwritten" {
    printf '[sshd]\nignoreip = 192.0.2.1\nbantime = 123\n' > "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local"
    cp "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local" "$BATS_TEST_TMPDIR/before"
    run configure_fail2ban_allowlist '192.0.2.5'
    [ "$status" -ne 0 ]
    cmp "$BATS_TEST_TMPDIR/before" "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local"
}
@test "later override is reported and previous file restored" {
    configure_fail2ban_allowlist '192.0.2.5'
    cp "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local" "$BATS_TEST_TMPDIR/before"
    printf '[sshd]\nignoreip = 192.0.2.1\n' > "$FT_FAIL2BAN_DIR/jail.d/zzzz-operator.local"
    run configure_fail2ban_allowlist '192.0.2.6'
    [ "$status" -ne 0 ]
    cmp "$BATS_TEST_TMPDIR/before" "$FT_FAIL2BAN_DIR/jail.d/zz-familytraffic-allowlist.local"
}
