#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "installer libraries provide inode-preserving writes" {
    # Exercise the real loader with its readonly project path.
    run bash -c '
        set -euo pipefail
        cd "$1"
        source <(sed '\''/^main "\$@"$/d; /^SCRIPT_DIR=/c\SCRIPT_DIR="$PWD"'\'' install.sh)
        source_libraries
        printf updated > "$2/source"
        printf original > "$2/target"
        inode=$(stat -c %i "$2/target")
        write_preserving_inode "$2/source" "$2/target"
        [[ $(cat "$2/target") == updated ]]
        [[ $(stat -c %i "$2/target") == "$inode" ]]
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "user management preserves installer SCRIPT_DIR" {
    run bash -c '
        set -euo pipefail
        readonly SCRIPT_DIR="$1"
        source "$1/lib/common.sh"
        source "$1/lib/user_management.sh"
        [[ "$SCRIPT_DIR" == "$1" ]]
        declare -F generate_qr_code
        declare -F create_user
    ' _ "$PROJECT_ROOT"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "users database initialization reports failed persistence" {
    run bash -c '
        set -euo pipefail
        USERS_JSON="$2/users.json"
        source "$1/lib/common.sh"
        source "$1/lib/orchestrator.sh"
        write_preserving_inode() { return 1; }
        if create_users_json; then exit 42; fi
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "proxy whitelist initialization reports failed persistence" {
    run bash -c '
        set -euo pipefail
        source "$1/lib/common.sh"
        source "$1/lib/orchestrator.sh"
        write_preserving_inode() { return 1; }
        # Override only the fixed installation directory in the function for isolation.
        eval "$(declare -f init_proxy_allowed_ips | sed "s|\${CONFIG_DIR}|$2|g")"
        if init_proxy_allowed_ips; then exit 42; fi
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "database initialization writes timestamps and localhost whitelist" {
    run bash -c '
        set -euo pipefail
        USERS_JSON="$2/users.json"
        source "$1/lib/common.sh"
        source "$1/lib/orchestrator.sh"
        eval "$(declare -f init_proxy_allowed_ips | sed "s|\${CONFIG_DIR}|$2|g")"
        create_users_json
        init_proxy_allowed_ips
        jq -e '\''.users == [] and (.metadata.created | length > 0) and .metadata.created == .metadata.last_modified'\'' "$USERS_JSON"
        jq -e '\''.allowed_ips == ["127.0.0.1"] and (.metadata.created | length > 0)'\'' "$2/proxy_allowed_ips.json"
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -eq 0 ]
}
