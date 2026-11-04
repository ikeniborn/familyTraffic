#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export USERS_JSON="$BATS_TEST_TMPDIR/users.json" XRAY_CONFIG="$BATS_TEST_TMPDIR/xray.json"
    export ENV_FILE="$BATS_TEST_TMPDIR/settings" CLIENTS_DIR="$BATS_TEST_TMPDIR/clients"
    export LOCK_FILE="$BATS_TEST_TMPDIR/users.lock" VLESS_HOME="$BATS_TEST_TMPDIR"
    source "$PROJECT_ROOT/lib/user_management.sh"
    cat > "$USERS_JSON" <<'JSON'
{"users":[{"username":"alice","uuid":"uuid-alice","connection_type":"proxy","proxy_password":"fixture-alice"},{"username":"bob","uuid":"uuid-bob","connection_type":"proxy","proxy_password":"fixture-bob"}]}
JSON
    cat > "$XRAY_CONFIG" <<'JSON'
{"inbounds":[{"tag":"reality","protocol":"vless","settings":{"clients":[{"id":"uuid-alice"},{"id":"uuid-bob"}]},"streamSettings":{"realitySettings":{"shortIds":[]}}},{"tag":"socks5-proxy","protocol":"socks","settings":{"auth":"password","accounts":[{"user":"alice","pass":"fixture-alice"},{"user":"bob","pass":"fixture-bob"}]}},{"tag":"http-proxy","protocol":"http","settings":{"accounts":[{"user":"alice","pass":"fixture-alice"},{"user":"bob","pass":"fixture-bob"}]}}]}
JSON
    printf 'ENABLE_PUBLIC_PROXY=true\n' > "$ENV_FILE"
    mkdir -p "$CLIENTS_DIR/alice"
    printf 'fixture client\n' > "$CLIENTS_DIR/alice/config.txt"
    cp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
    # Model the Docker boundary; production removal and reload logic remain real.
    docker() {
        case "$1" in
            ps) printf 'familytraffic\n' ;;
            run) return 0 ;;
            exec)
                if [[ -e "$BATS_TEST_TMPDIR/fail-reload" ]]; then
                    return 1
                fi
                command cp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
                ;;
            *) return 99 ;;
        esac
    }
}

snapshot() {
    cp "$USERS_JSON" "$BATS_TEST_TMPDIR/users.before"
    cp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/xray.before"
    users_inode=$(stat -c %i "$USERS_JSON")
    config_inode=$(stat -c %i "$XRAY_CONFIG")
}

assert_unchanged() {
    cmp "$USERS_JSON" "$BATS_TEST_TMPDIR/users.before"
    cmp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/xray.before"
    [ "$(stat -c %i "$USERS_JSON")" = "$users_inode" ]
    [ "$(stat -c %i "$XRAY_CONFIG")" = "$config_inode" ]
    [ -f "$CLIENTS_DIR/alice/config.txt" ]
}

single_account() {
    jq '.users |= map(select(.username == "alice"))' "$USERS_JSON" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$USERS_JSON"
    jq '(.inbounds[] | select(.tag == "socks5-proxy" or .tag == "http-proxy") | .settings.accounts) |= map(select(.user == "alice"))' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$XRAY_CONFIG"
}

@test "last public proxy account removal fails without changing files or client exports" {
    single_account
    snapshot
    run remove_user alice
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"last proxy account"* ]]
    assert_unchanged
}

@test "legacy last account refusal does not migrate the database" {
    single_account
    jq 'del(.users[0].connection_type)' "$USERS_JSON" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$USERS_JSON"
    snapshot
    run remove_user alice
    [ "$status" -ne 0 ]
    assert_unchanged
}

@test "reload failure preserves user database and restores config bytes and inode" {
    touch "$BATS_TEST_TMPDIR/fail-reload"
    snapshot
    run remove_user alice
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"removed successfully"* ]]
    assert_unchanged
    cmp "$BATS_TEST_TMPDIR/live.json" "$XRAY_CONFIG"
}

@test "permitted removal updates database applied accounts and client exports" {
    snapshot
    run remove_user alice
    echo "$output"
    [ "$status" -eq 0 ]
    jq -e '[.users[].username] == ["bob"]' "$USERS_JSON"
    jq -e '[.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy") | [.settings.accounts[].user]] == [["bob"],["bob"]]' "$XRAY_CONFIG"
    cmp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
    [ ! -e "$CLIENTS_DIR/alice" ]
    [ "$(stat -c %i "$XRAY_CONFIG")" = "$config_inode" ]
}

@test "VPN-only removal remains permitted with one public proxy account" {
    jq '.users[0].connection_type = "vpn"' "$USERS_JSON" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$USERS_JSON"
    jq '(.inbounds[] | select(.tag == "http-proxy" or .tag == "socks5-proxy") | .settings.accounts) |= map(select(.user == "bob"))' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$XRAY_CONFIG"
    run remove_user alice
    echo "$output"
    [ "$status" -eq 0 ]
    jq -e '[.users[].username] == ["bob"]' "$USERS_JSON"
    jq -e '.inbounds[0].settings.clients == [{"id":"uuid-bob"}]' "$XRAY_CONFIG"
}

@test "one empty receiver blocks removal even when another receiver has a spare account" {
    jq '(.inbounds[] | select(.tag == "http-proxy") | .settings.accounts) |= map(select(.user == "alice"))' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$XRAY_CONFIG"
    snapshot
    run remove_user alice
    [ "$status" -ne 0 ]
    assert_unchanged
}

@test "partial combined-user config failure restores VPN and proxy accounts" {
    jq '.users[0].connection_type = "both"' "$USERS_JSON" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$USERS_JSON"
    remove_proxy_accounts() { printf '{}' > "$XRAY_CONFIG"; return 1; }
    snapshot
    run remove_user alice
    [ "$status" -ne 0 ]
    assert_unchanged
    cmp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
}

@test "database persistence failure restores saved and applied accounts" {
    eval "$(declare -f write_preserving_inode | sed '1s/write_preserving_inode/original_write/')"
    write_preserving_inode() {
        if [[ "$1" == */users.next ]]; then
            printf '{}' > "$2"
            return 1
        fi
        original_write "$@"
    }
    snapshot
    run remove_user alice
    [ "$status" -ne 0 ]
    assert_unchanged
    cmp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
}

@test "concurrent removals retain one authenticated account" {
    remove_user alice > "$BATS_TEST_TMPDIR/alice.log" 2>&1 &
    local alice_pid=$!
    remove_user bob > "$BATS_TEST_TMPDIR/bob.log" 2>&1 &
    local bob_pid=$!
    local alice_status=0 bob_status=0
    wait "$alice_pid" || alice_status=$?
    wait "$bob_pid" || bob_status=$?
    [ "$((alice_status + bob_status))" -eq 1 ]
    jq -e '.users | length == 1' "$USERS_JSON"
    jq -e --slurpfile users "$USERS_JSON" '[.inbounds[] | select(.tag == "socks5-proxy" or .tag == "http-proxy") | [.settings.accounts[].user]] == [[$users[0].users[0].username],[$users[0].users[0].username]]' "$XRAY_CONFIG"
    cmp "$XRAY_CONFIG" "$BATS_TEST_TMPDIR/live.json"
}

@test "last proxy user can be removed when managed public proxy receivers are absent" {
    single_account
    jq '.inbounds |= map(select(.tag == "reality"))' "$XRAY_CONFIG" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$XRAY_CONFIG"
    run remove_user alice
    echo "$output"
    [ "$status" -eq 0 ]
    jq -e '.users == []' "$USERS_JSON"
    [ "$(stat -c %a "$USERS_JSON")" = 600 ]
}

@test "VPN config write failure cannot report removal success or delete the user" {
    jq '.users[0].connection_type = "vpn"' "$USERS_JSON" > "$BATS_TEST_TMPDIR/staged"
    cat "$BATS_TEST_TMPDIR/staged" > "$USERS_JSON"
    eval "$(declare -f write_preserving_inode | sed '1s/write_preserving_inode/original_write/')"
    write_preserving_inode() {
        if [[ "$1" == "$XRAY_CONFIG".tmp.* ]]; then return 1; fi
        original_write "$@"
    }
    snapshot
    run remove_user alice
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"removed successfully"* ]]
    assert_unchanged
}
