#!/usr/bin/env bats
# tests/unit/test_os_detection.bats - Unit tests for OS detection module

load ../test_helper

setup() {
    setup_test_env
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/os_detection.sh"
}

teardown() {
    teardown_test_env
}

@test "detect_os succeeds when os-release exists" {
    skip_if_not_root

    run detect_os
    [ "$status" -eq 0 ]
}

@test "detect_os identifies operating system" {
    skip_if_not_root

    run detect_os
    [ "$status" -eq 0 ]
    # Should output OS name
    [[ "$output" =~ (Ubuntu|Debian|CentOS|Fedora) ]]
}

# The support check is validate_os, and it reads the OS_ID/OS_VERSION pair that
# detect_os exports — not the OS_NAME an earlier version of this suite mocked.
@test "validate_os accepts Ubuntu 22.04" {
    OS_ID="ubuntu"
    OS_VERSION="22.04"
    OS_VERSION_CODENAME="jammy"

    run validate_os
    [ "$status" -eq 0 ]
}

@test "validate_os accepts Debian 11" {
    OS_ID="debian"
    OS_VERSION="11"
    OS_VERSION_CODENAME="bullseye"

    run validate_os
    [ "$status" -eq 0 ]
}

@test "validate_os rejects an unsupported distribution" {
    OS_ID="windows"
    OS_VERSION="10"
    OS_VERSION_CODENAME="none"

    run validate_os
    [ "$status" -eq 1 ]
}

@test "validate_os fails when detect_os has not run" {
    OS_ID=""
    OS_VERSION=""

    run validate_os
    [ "$status" -eq 1 ]
}

# get_package_manager reports through the exported PKG_MANAGER, not stdout, so
# it is called directly — `run` would confine the export to a subshell.
@test "get_package_manager selects apt on a Debian-based host" {
    PKG_MANAGER=""

    get_package_manager
    [ "$?" -eq 0 ]
    [[ "$PKG_MANAGER" == "apt" || "$PKG_MANAGER" == "apt-get" ]]
}

# Removed: check_system_requirements and detect_architecture assertions.
# Neither function exists in lib/os_detection.sh, which declares detect_os,
# validate_os, get_package_manager, and print_os_info. They were not renamed
# during the v5.33 refactor — the repository has never defined them.
