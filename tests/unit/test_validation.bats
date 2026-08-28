#!/usr/bin/env bats
# tests/unit/test_validation.bats - Unit tests for the input validators
#
# v5.33 reduced lib/validation.sh to two reverse-proxy no-op stubs and moved
# the real validators into the modules that own them, so each is sourced from
# its current home:
#   validate_username        lib/user_management.sh (needs common.sh first)
#   validate_port/_subnet    lib/network_params.sh
#   validate_ip              lib/common.sh
#
# validate_ip was duplicated in proxy_whitelist.sh and ufw_whitelist.sh; the
# latter capped every CIDR prefix at 32 and, being sourced last by the CLI,
# rejected ordinary IPv6 networks. The IPv6 cases below cover that regression.

load ../test_helper

setup() {
    setup_test_env
    source "${LIB_DIR}/logger.sh"
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/user_management.sh"
    source "${LIB_DIR}/network_params.sh"
    source "${LIB_DIR}/proxy_whitelist.sh"
}

teardown() {
    teardown_test_env
}

# Username validation tests
@test "validate_username accepts valid alphanumeric username" {
    run validate_username "user123"
    [ "$status" -eq 0 ]
}

@test "validate_username accepts username with underscore" {
    run validate_username "user_name"
    [ "$status" -eq 0 ]
}

@test "validate_username accepts username with dash" {
    run validate_username "user-name"
    [ "$status" -eq 0 ]
}

@test "validate_username rejects empty username" {
    run validate_username ""
    [ "$status" -eq 1 ]
}

@test "validate_username rejects username with spaces" {
    run validate_username "user name"
    [ "$status" -eq 1 ]
}

@test "validate_username rejects username with special characters" {
    run validate_username "user@name"
    [ "$status" -eq 1 ]
}

@test "validate_username rejects very long username" {
    local long_name=$(printf 'a%.0s' {1..100})
    run validate_username "$long_name"
    [ "$status" -eq 1 ]
}

# Port validation tests
@test "validate_port accepts valid port 443" {
    run validate_port "443"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts valid port 8443" {
    run validate_port "8443"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 1024" {
    run validate_port "1024"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 65535" {
    run validate_port "65535"
    [ "$status" -eq 0 ]
}

@test "validate_port rejects port 0" {
    run validate_port "0"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects port 65536" {
    run validate_port "65536"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects negative port" {
    run validate_port "-1"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric port" {
    run validate_port "abc"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects empty port" {
    run validate_port ""
    [ "$status" -eq 1 ]
}

# IP address validation tests
@test "validate_ip accepts valid IP 192.168.1.1" {
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts valid IP 10.0.0.1" {
    run validate_ip "10.0.0.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts valid IP 172.16.0.1" {
    run validate_ip "172.16.0.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects invalid IP 256.1.1.1" {
    run validate_ip "256.1.1.1"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects invalid IP 192.168.1" {
    run validate_ip "192.168.1"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects invalid IP with text" {
    run validate_ip "192.168.1.abc"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects empty IP" {
    run validate_ip ""
    [ "$status" -eq 1 ]
}

@test "validate_ip accepts IPv4 CIDR 10.0.0.0/8" {
    run validate_ip "10.0.0.0/8"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects IPv4 CIDR prefix above 32" {
    run validate_ip "10.0.0.0/33"
    [ "$status" -eq 1 ]
}

@test "validate_ip accepts plain IPv6" {
    run validate_ip "2001:db8::1"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts IPv6 loopback" {
    run validate_ip "::1"
    [ "$status" -eq 0 ]
}

# The regression behind CQ-002: a /64 is an ordinary IPv6 network, but the
# shadowing implementation capped every prefix at 32 and rejected it.
@test "validate_ip accepts IPv6 CIDR 2001:db8::/64" {
    run validate_ip "2001:db8::/64"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects IPv6 CIDR prefix above 128" {
    run validate_ip "2001:db8::/129"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects IPv6-shaped garbage" {
    run validate_ip "zzzz::1"
    [ "$status" -eq 1 ]
}

# Subnet validation tests
@test "validate_subnet accepts valid subnet 172.20.0.0/16" {
    run validate_subnet "172.20.0.0/16"
    [ "$status" -eq 0 ]
}

@test "validate_subnet accepts valid subnet 10.0.0.0/8" {
    run validate_subnet "10.0.0.0/8"
    [ "$status" -eq 0 ]
}

@test "validate_subnet accepts valid subnet 192.168.0.0/24" {
    run validate_subnet "192.168.0.0/24"
    [ "$status" -eq 0 ]
}

@test "validate_subnet rejects subnet without CIDR" {
    run validate_subnet "172.20.0.0"
    [ "$status" -eq 1 ]
}

@test "validate_subnet rejects subnet with invalid CIDR" {
    run validate_subnet "172.20.0.0/33"
    [ "$status" -eq 1 ]
}

@test "validate_subnet rejects empty subnet" {
    run validate_subnet ""
    [ "$status" -eq 1 ]
}

# Removed: validate_uuid, validate_domain, and validate_path assertions.
#
# None of the three is defined anywhere in this repository — they are not
# functions that moved during the v5.33 refactor, they never existed. UUIDs are
# generated, never parsed from input; domains are checked by the purpose-built
# validate_dns_for_domain, validate_mtproxy_domain, and validate_fake_tls_domain
# rather than a generic syntax validator.
#
# Adding production functions solely to satisfy these assertions would invert
# the point of a test suite, so the assertions go instead.
