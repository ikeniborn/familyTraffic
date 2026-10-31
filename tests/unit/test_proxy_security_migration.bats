#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TRACE="$BATS_TEST_TMPDIR/trace"
    export TRACE
}

@test "security check invokes only read-only inspection" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    security_inspect() { echo inspect >> "$TRACE"; return 1; }
    security_apply() { echo mutate >> "$TRACE"; }
    run security_check
    [ "$status" -ne 0 ]
    [ "$(cat "$TRACE")" = inspect ]
}

@test "mutable image is rejected before mutation" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    security_preflight() { echo mutation >> "$TRACE"; }
    run security_reconcile familytraffic:latest
    [ "$status" -ne 0 ]
    [ ! -e "$TRACE" ]
}

@test "validation precedes backup apply traffic firewall jail and final inspection" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    security_preflight() { echo validate >> "$TRACE"; }
    security_backup() { echo backup >> "$TRACE"; }
    security_apply() { echo apply >> "$TRACE"; }
    security_verify_traffic() { echo traffic >> "$TRACE"; }
    security_reconcile_policy() { echo policy >> "$TRACE"; }
    security_inspect() { echo inspect >> "$TRACE"; }
    security_cleanup() { :; }
    run security_reconcile "sha256:$(printf '%064d' 1)"
    [ "$status" -eq 0 ]
    [ "$(cat "$TRACE")" = $'validate\nbackup\napply\ntraffic\npolicy\ninspect' ]
}

@test "preflight failure does not apply or rollback host state" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    security_preflight() { echo validate >> "$TRACE"; return 1; }
    security_backup() { echo backup >> "$TRACE"; }
    security_rollback() { echo rollback >> "$TRACE"; }
    security_cleanup() { :; }
    run security_reconcile "sha256:$(printf '%064d' 1)"
    [ "$status" -ne 0 ]
    [ "$(cat "$TRACE")" = validate ]
}

@test "each post-backup failure rolls back and remains a failed deployment" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    security_preflight() { echo validate >> "$TRACE"; }
    security_backup() { echo backup >> "$TRACE"; }
    security_cleanup() { :; }
    security_rollback() { echo rollback >> "$TRACE"; }
    for fail in apply traffic policy inspect; do
        export FAIL_STAGE="$fail"
        : > "$TRACE"
        security_apply() { echo apply >> "$TRACE"; [[ "$FAIL_STAGE" != apply ]]; }
        security_verify_traffic() { echo traffic >> "$TRACE"; [[ "$FAIL_STAGE" != traffic ]]; }
        security_reconcile_policy() { echo policy >> "$TRACE"; [[ "$FAIL_STAGE" != policy ]]; }
        security_inspect() { echo inspect >> "$TRACE"; [[ "$FAIL_STAGE" != inspect ]]; }
        run security_reconcile "sha256:$(printf '%064d' 1)"
        [ "$status" -ne 0 ]
        [ "$(tail -1 "$TRACE")" = rollback ]
    done
}

@test "nginx staging preserves unrelated bytes and forwards four proxy sources" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    cat > "$BATS_TEST_TMPDIR/nginx.conf" <<'CONF'
stream {
    server {
        listen 443;
        proxy_pass $reality;
    }
    server {
        listen 1080 ssl;
        proxy_pass 127.0.0.1:10800;
    }
    server {
        listen 8118 ssl;
        proxy_pass 127.0.0.1:18118;
    }
}
http { # Custom Tier2 bytes stay here.
    server { listen 8448 ssl; }
}
CONF
    run security_stage_nginx "$BATS_TEST_TMPDIR/nginx.conf" "$BATS_TEST_TMPDIR/staged.conf" true
    [ "$status" -eq 0 ]
    [ "$(grep -c 'proxy_protocol on;' "$BATS_TEST_TMPDIR/staged.conf")" -eq 4 ]
    grep -F 'http { # Custom Tier2 bytes stay here.' "$BATS_TEST_TMPDIR/staged.conf"
    grep -F 'proxy_pass $reality;' "$BATS_TEST_TMPDIR/staged.conf"
}

@test "nginx staging rejects incoming public source metadata" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    printf '%s\n' 'stream { server { listen 1080 ssl proxy_protocol; proxy_pass 127.0.0.1:10800; } }' > "$BATS_TEST_TMPDIR/nginx.conf"
    run security_stage_nginx "$BATS_TEST_TMPDIR/nginx.conf" "$BATS_TEST_TMPDIR/staged.conf" false
    [ "$status" -ne 0 ]
}

@test "apply persists immutable image and rollback preserves user bytes and config inodes" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    SECURITY_ROOT="$BATS_TEST_TMPDIR/deploy"
    SECURITY_WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$SECURITY_ROOT/config/nginx" "$SECURITY_ROOT/data" "$SECURITY_WORK"
    SECURITY_XRAY="$SECURITY_ROOT/config/xray_config.json"
    SECURITY_NGINX="$SECURITY_ROOT/config/nginx/nginx.conf"
    SECURITY_USERS="$SECURITY_ROOT/data/users.json"
    SECURITY_OVERRIDE="$SECURITY_ROOT/docker-compose.security.yml"
    printf old-xray > "$SECURITY_XRAY"
    printf old-nginx > "$SECURITY_NGINX"
    printf saved-users > "$SECURITY_USERS"
    printf saved-env > "$SECURITY_ROOT/.env"
    printf saved-compose > "$SECURITY_ROOT/docker-compose.yml"
    printf new-xray > "$SECURITY_WORK/xray.json"
    printf new-nginx > "$SECURITY_WORK/nginx.conf"
    SECURITY_IMAGE="sha256:$(printf '%064d' 1)"
    SECURITY_OLD_IMAGE="sha256:$(printf '%064d' 2)"
    SECURITY_PORTS=1080,8118
    SECURITY_NOTLS=true
    SECURITY_FIREWALL_CHANGES=''
    SECURITY_USER_HASH=$(security_user_fingerprint)
    SECURITY_CONFIG_HASH=$(sha256sum "$SECURITY_XRAY" "$SECURITY_NGINX" "$SECURITY_USERS" "$SECURITY_ROOT/.env" "$SECURITY_ROOT/docker-compose.yml")
    xray_inode=$(stat -c %i "$SECURITY_XRAY")
    nginx_inode=$(stat -c %i "$SECURITY_NGINX")
    env_inode=$(stat -c %i "$SECURITY_ROOT/.env")
    FT_FAIL2BAN_DIR="$BATS_TEST_TMPDIR/fail2ban"
    FT_LOGROTATE_DIR="$BATS_TEST_TMPDIR/logrotate"
    ufw() { echo 'Status: active'; }
    validate_proxy_jail_ownership() { return 0; }
    security_compose() { echo "compose $*" >> "$TRACE"; }
    security_compose_with_old() { echo "old-compose $*" >> "$TRACE"; }
    docker() { echo "docker $*" >> "$TRACE"; }
    security_backup
    security_apply
    grep -F "image: $SECURITY_IMAGE" "$SECURITY_OVERRIDE"
    [ "$(cat "$SECURITY_XRAY")" = new-xray ]
    [ "$(cat "$SECURITY_NGINX")" = new-nginx ]
    grep -Fx 'PROXY_NOTLS_ENABLED=true' "$SECURITY_ROOT/.env"
    [ "$(security_user_fingerprint)" = "$SECURITY_USER_HASH" ]
    security_rollback
    [ "$(cat "$SECURITY_XRAY")" = old-xray ]
    [ "$(cat "$SECURITY_NGINX")" = old-nginx ]
    [ "$(stat -c %i "$SECURITY_XRAY")" = "$xray_inode" ]
    [ "$(stat -c %i "$SECURITY_NGINX")" = "$nginx_inode" ]
    [ "$(cat "$SECURITY_ROOT/.env")" = saved-env ]
    [ "$(stat -c %i "$SECURITY_ROOT/.env")" = "$env_inode" ]
    [ ! -e "$SECURITY_OVERRIDE" ]
    grep -F "image: $SECURITY_OLD_IMAGE" "$SECURITY_WORK/rollback.yml"
    [ "$(security_user_fingerprint)" = "$SECURITY_USER_HASH" ]
}

@test "failed regenerated account validation preserves active configuration bytes and inode" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    source <(sed -n '/^create_xray_config()/,/^# ===/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    XRAY_CONFIG="$BATS_TEST_TMPDIR/active.json"
    USERS_JSON="$BATS_TEST_TMPDIR/users.json"
    printf old-active > "$XRAY_CONFIG"
    printf '%s\n' '{"users":[]}' > "$USERS_JSON"
    original_inode=$(stat -c %i "$XRAY_CONFIG")
    PRIVATE_KEY=fixture SHORT_ID=fixture REALITY_DEST=example.com REALITY_DEST_PORT=443 VLESS_PORT=8443
    DETECTED_DNS_PRIMARY='' ENABLE_PUBLIC_PROXY=true
    CYAN='' NC='' RED='' GREEN=''
    generate_routing_json() { printf ',"routing":{"rules":[]}'; }
    generate_socks5_inbound_json() { printf ',{"tag":"socks5-proxy","protocol":"socks","settings":{"auth":"password","accounts":[]}}'; }
    generate_http_inbound_json() { printf ',{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}'; }
    run create_xray_config true
    [ "$status" -ne 0 ]
    [ "$(cat "$XRAY_CONFIG")" = old-active ]
    [ "$(stat -c %i "$XRAY_CONFIG")" = "$original_inode" ]
}

@test "fresh bootstrap creates first proxy user offline without Docker or password output" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    source <(sed -n '/^provision_initial_proxy_user()/,/^# ===/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    USERS_JSON="$BATS_TEST_TMPDIR/users.json"
    LOCK_FILE="$BATS_TEST_TMPDIR/users.lock"
    SCRIPT_DIR_LIB="$PROJECT_ROOT/lib"
    FT_INITIAL_PROXY_USERNAME=fixture_user
    printf '%s\n' '{"users":[],"metadata":{}}' > "$USERS_JSON"
    inode=$(stat -c %i "$USERS_JSON")
    docker() { echo called >> "$TRACE"; return 1; }
    run provision_initial_proxy_user
    [ "$status" -eq 0 ]
    [ ! -e "$TRACE" ]
    jq -e '.users | length == 1' "$USERS_JSON"
    password=$(jq -r '.users[0].proxy_password' "$USERS_JSON")
    [[ "$password" =~ ^[a-f0-9]{32}$ ]]
    [[ "$output" != *"$password"* ]]
    [ "$(stat -c %i "$USERS_JSON")" = "$inode" ]
}

@test "installer refuses existing users before directory or key mutation" {
    source <(sed -n '/^orchestrate_installation()/,/^# ===/p' "$PROJECT_ROOT/lib/orchestrator.sh")
    USERS_JSON="$BATS_TEST_TMPDIR/users.json"
    printf '%s\n' '{"users":[{"username":"existing"}]}' > "$USERS_JSON"
    BLUE='' NC=''
    create_directory_structure() { echo mutate >> "$TRACE"; return 1; }
    run orchestrate_installation
    [ "$status" -ne 0 ]
    [ ! -e "$TRACE" ]
}

@test "Xray reload rejects empty public accounts before invoking Docker" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    source <(sed -n '/^reload_xray()/,/^}/p' "$PROJECT_ROOT/lib/user_management.sh")
    XRAY_CONFIG="$BATS_TEST_TMPDIR/config.json"
    printf '%s\n' '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}]}' > "$XRAY_CONFIG"
    log_error() { :; }
    docker() { echo mutate >> "$TRACE"; }
    run reload_xray
    [ "$status" -ne 0 ]
    [ ! -e "$TRACE" ]
}

@test "ownership preflight allows planned journal creation but rejects dangling symlink" {
    source "$PROJECT_ROOT/lib/fail2ban_setup.sh"
    FT_FAIL2BAN_DIR="$BATS_TEST_TMPDIR/fail2ban"
    FT_LOGROTATE_DIR="$BATS_TEST_TMPDIR/logrotate"
    FT_PROXY_AUTH_LOG="$BATS_TEST_TMPDIR/auth.log"
    run validate_proxy_jail_ownership 1080,8118 allow-missing-log
    [ "$status" -eq 0 ]
    [ ! -e "$FT_PROXY_AUTH_LOG" ]
    [ ! -e "$FT_FAIL2BAN_DIR" ]
    ln -s "$BATS_TEST_TMPDIR/absent-target" "$FT_PROXY_AUTH_LOG"
    run validate_proxy_jail_ownership 1080,8118 allow-missing-log
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/absent-target" ]
}

@test "check CLI never starts containers or mutates firewall even when protection is absent" {
    export FT_SECURITY_ROOT="$BATS_TEST_TMPDIR/deploy"
    mkdir -p "$FT_SECURITY_ROOT/config/nginx" "$BATS_TEST_TMPDIR/bin"
    printf '%s\n' '{"inbounds":[]}' > "$FT_SECURITY_ROOT/config/xray_config.json"
    printf 'PROXY_NOTLS_ENABLED=false\n' > "$FT_SECURITY_ROOT/.env"
    printf 'stream {}\n' > "$FT_SECURITY_ROOT/config/nginx/nginx.conf"
    for command in docker ufw fail2ban-client; do
        cat > "$BATS_TEST_TMPDIR/bin/$command" <<'MOCK'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TRACE"
exit 1
MOCK
        chmod +x "$BATS_TEST_TMPDIR/bin/$command"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$PROJECT_ROOT/scripts/familytraffic-security" check
    [ "$status" -ne 0 ]
    if [[ -f "$TRACE" ]]; then
        ! grep -Eq 'docker (run|create|compose)|ufw (allow|limit|delete|reload)|fail2ban-client (reload|restart|set)' "$TRACE"
    fi
}

@test "installed-style security CLI symlink resolves repository libraries" {
    mkdir -p "$BATS_TEST_TMPDIR/sbin" "$BATS_TEST_TMPDIR/deploy/config"
    ln -s "$PROJECT_ROOT/scripts/familytraffic-security" "$BATS_TEST_TMPDIR/sbin/familytraffic-security"
    export FT_SECURITY_ROOT="$BATS_TEST_TMPDIR/deploy"
    unset FT_SECURITY_LIB_DIR
    run "$BATS_TEST_TMPDIR/sbin/familytraffic-security" check
    [ "$status" -ne 0 ]
    [[ "$output" == *'Proxy authentication preflight failed:'* ]]
    [[ "$output" != *'proxy_security.sh: No such file or directory'* ]]
    [[ "$output" != *'fail2ban_setup.sh: No such file or directory'* ]]
}

@test "journal mount preflight rejects missing misdirected read-only and shadowed mounts" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    run security_validate_journal_mounts '[]' /opt/familytraffic/logs/xray
    [ "$status" -ne 0 ]
    for mounts in '[{"Type":"bind","Source":"/wrong","Destination":"/var/log/xray","RW":true}]' '[{"Type":"bind","Source":"/opt/familytraffic/logs/xray","Destination":"/var/log/xray","RW":false}]' '[{"Type":"bind","Source":"/opt/familytraffic/logs/xray","Destination":"/var/log/xray","RW":true},{"Type":"bind","Source":"/wrong/auth.log","Destination":"/var/log/xray/auth.log","RW":true}]'; do
        run security_validate_journal_mounts "$mounts" /opt/familytraffic/logs/xray
        [ "$status" -ne 0 ]
    done
    run security_validate_journal_mounts '[{"Type":"bind","Source":"/opt/familytraffic/logs/xray","Destination":"/var/log/xray","RW":true}]' /opt/familytraffic/logs/xray
    [ "$status" -eq 0 ]
}

@test "controlled rejection requires a fresh event and does not expose account secrets" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    SECURITY_WORK="$BATS_TEST_TMPDIR/work"
    SECURITY_LOG="$BATS_TEST_TMPDIR/auth.log"
    SECURITY_XRAY="$BATS_TEST_TMPDIR/xray.json"
    mkdir -p "$SECURITY_WORK" "$BATS_TEST_TMPDIR/bin"
    printf '%s\n' '{"inbounds":[{"tag":"http-proxy","settings":{"accounts":[{"user":"fixture-user","pass":"secret-fixture-value"}]}}]}' > "$SECURITY_XRAY"
    printf '%s\n' 'proxy = "https://proxy.lab:8118"' 'proxy-user = "fixture-user:secret-fixture-value"' > "$SECURITY_WORK/probe.curl"
    : > "$SECURITY_LOG"
    chmod 600 "$SECURITY_LOG"
    export TEST_EVENT_LOG="$SECURITY_LOG"
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'MOCK'
#!/bin/bash
if [[ "${TEST_WRITE_EVENT:-false}" == true ]]; then
    printf '%s FT_AUTH_FAILURE protocol=http src=127.0.0.2\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TEST_EVENT_LOG"
fi
printf 407
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run security_verify_auth_event
    [ "$status" -ne 0 ]
    [[ "$output" != *secret-fixture-value* ]]
    export TEST_WRITE_EVENT=true
    run security_verify_auth_event
    [ "$status" -eq 0 ]
    [[ "$output" != *secret-fixture-value* ]]
}

@test "failed preflight cannot delete an inherited transaction workspace" {
    source "$PROJECT_ROOT/scripts/familytraffic-security"
    SECURITY_WORK="$BATS_TEST_TMPDIR/protected"
    mkdir "$SECURITY_WORK"
    printf durable-fixture > "$SECURITY_WORK/state"
    security_preflight() { return 1; }
    run security_reconcile "sha256:$(printf '%064d' 1)"
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/protected/state")" = durable-fixture ]
}
