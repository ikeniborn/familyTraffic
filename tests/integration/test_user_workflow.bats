#!/usr/bin/env bats
# tests/integration/test_user_workflow.bats - Integration tests for user workflow

load ../test_helper

setup() {
    skip_if_not_root
    setup_test_env

    # Source required modules
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/common.sh"

    # Create mock installation
    export INSTALL_DIR="$MOCK_INSTALL_DIR"
    export CONFIG_DIR="${INSTALL_DIR}/config"
    export DATA_DIR="${INSTALL_DIR}/data"

    # Create mock files
    create_mock_xray_config "${CONFIG_DIR}/xray_config.json"
    create_mock_users_json "${DATA_DIR}/users.json" 0

    # Source user management module
    source "${LIB_DIR}/user_management.sh" 2>/dev/null || true
}

teardown() {
    teardown_test_env
}

@test "create user adds user to users.json" {
    skip "Requires full system setup"

    local username="testuser"

    # Create user
    run create_user "$username"
    [ "$status" -eq 0 ]

    # Verify user exists in JSON
    local user_exists
    user_exists=$(jq -e ".users[] | select(.username == \"$username\")" "${DATA_DIR}/users.json")
    [ -n "$user_exists" ]
}

@test "create user generates UUID" {
    skip "Requires full system setup"

    local username="testuser"

    # Create user
    run create_user "$username"
    [ "$status" -eq 0 ]

    # Verify UUID format. There is no validate_uuid in this repository — UUIDs are
    # generated, never parsed from input — so the shape is asserted directly.
    local uuid
    uuid=$(jq -r ".users[] | select(.username == \"$username\") | .uuid" "${DATA_DIR}/users.json")
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "create user creates client directory" {
    skip "Requires full system setup"

    local username="testuser"

    # Create user
    run create_user "$username"
    [ "$status" -eq 0 ]

    # Verify directory exists
    assert_dir_exists "${DATA_DIR}/clients/${username}"
}

@test "remove user deletes from users.json" {
    skip "Requires full system setup"

    local username="testuser"

    # Create then remove user
    create_user "$username"
    run remove_user "$username"
    [ "$status" -eq 0 ]

    # Verify user doesn't exist
    local user_exists
    user_exists=$(jq -e ".users[] | select(.username == \"$username\")" "${DATA_DIR}/users.json" || echo "")
    [ -z "$user_exists" ]
}

@test "full user lifecycle: create, verify, remove" {
    skip "Requires full system setup"

    local username="testuser"

    # Create user
    create_user "$username"

    # Verify existence
    local user_count
    user_count=$(jq '.users | length' "${DATA_DIR}/users.json")
    [ "$user_count" -eq 1 ]

    # Remove user
    remove_user "$username"

    # Verify removal
    user_count=$(jq '.users | length' "${DATA_DIR}/users.json")
    [ "$user_count" -eq 0 ]
}

@test "concurrent user creation is safe" {
    skip "Requires full system setup"

    # Create multiple users concurrently
    create_user "user1" &
    create_user "user2" &
    create_user "user3" &
    wait

    # Verify all users exist
    local user_count
    user_count=$(jq '.users | length' "${DATA_DIR}/users.json")
    [ "$user_count" -eq 3 ]
}
