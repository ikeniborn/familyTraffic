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

@test "public proxy installation stops before certificate acquisition when UFW is inactive" {
    run bash -c '
        source <(sed '\''$d'\'' "$1")
        print_banner() { :; }
        check_root() { :; }
        source_libraries() { :; }
        detect_os() { :; }
        validate_os() { :; }
        get_package_manager() { :; }
        check_dependencies() { return 0; }
        install_dependencies() { :; }
        detect_old_installation() { OLD_INSTALL_FOUND=false; }
        collect_parameters() { ENABLE_PUBLIC_PROXY=true; ENABLE_PROXY_TLS=true; }
        ufw() { printf "Status: inactive\n"; }
        get_server_public_ip() { echo certificate-stage-reached; return 99; }
        main
    ' _ "$PROJECT_ROOT/install.sh"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UFW must be active before installing public proxies"* ]]
    [[ "$output" != *"certificate-stage-reached"* ]]
}

@test "CLI installation finds repository sources after deployment changes directory" {
    run bash -c '
        set -euo pipefail
        source "$1/lib/common.sh"
        cd "$1"
        source lib/orchestrator.sh
        cd "$2"
        # Capture the first CLI copy without writing installation paths.
        cp() { command cp "$1" "$capture"; return 1; }
        capture="$2/copied-cli"
        if install_cli_tools; then exit 42; fi
        cmp "$1/scripts/familytraffic" "$capture"
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -eq 0 ]
}
