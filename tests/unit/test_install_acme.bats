#!/usr/bin/env bats

load '../test_helper'

@test "TLS installation delegates ACME lifecycle to certificate acquisition" {
    run bash -c '
        source <(sed '\''$d'\'' "$1")
        trap - EXIT

        check_root() { :; }
        check_fresh_installation() { :; }
        source_libraries() { :; }
        detect_os() { :; }
        validate_os() { :; }
        get_package_manager() { :; }
        check_dependencies() { return 0; }
        install_dependencies() { :; }
        detect_old_installation() { OLD_INSTALL_FOUND=false; }
        select_service_mode() { :; }
        check_selected_ports() { :; }
        collect_parameters() {
            ENABLE_PUBLIC_PROXY=true
            ENABLE_PROXY_TLS=true
            DOMAIN=ft.example.com
            EMAIL=ops@example.com
        }
        ufw() { printf "Status: active\n"; }
        configure_install_firewall() { return 0; }
        get_server_public_ip() { printf "%s\n" "203.0.113.10"; }
        validate_domain_dns() { return 0; }
        install_certbot() { return 0; }
        install() { :; }
        obtain_certificate() {
            printf "%s\n" "obtain_certificate:$1:$2"
            return 1
        }

        main
    ' _ "${PROJECT_ROOT}/install.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"obtain_certificate:ft.example.com:ops@example.com"* ]]
    [[ "$output" == *"Certificate acquisition failed"* ]]
    [[ "$output" != *"command not found"* ]]
}

@test "ACME cleanup removes both temporary family rules and preserves operator rules" {
    source "$PROJECT_ROOT/lib/letsencrypt_integration.sh"
    PORT_80_OPENED_BY_US=true
    local trace="$BATS_TEST_TMPDIR/deleted"
    ufw() {
        case "$*" in
            status) echo 'Status: active' ;;
            'status numbered') printf '%s\n' '[ 1] 22/tcp ALLOW IN Anywhere # SSH' '[ 2] 80/tcp ALLOW IN Anywhere # ACME HTTP-01 challenge' '[ 3] 80/tcp (v6) ALLOW IN Anywhere (v6) # ACME HTTP-01 challenge' ;;
            *delete*) echo "$*" >> "$trace" ;;
        esac
    }
    close_port_80_for_certbot
    [ "$(sed 's/.*delete //' "$trace")" = $'3\n2' ]
}

@test "a failed ACME bind leaves an existing container untouched" {
    source "$PROJECT_ROOT/lib/letsencrypt_integration.sh"
    local trace="$BATS_TEST_TMPDIR/docker"
    : > "$trace"
    docker() {
        echo "$1" >> "$trace"
        if [[ $1 == ps ]]; then echo certbot_nginx; fi
    }
    ss() { echo 'LISTEN 0 80 127.0.0.1:80'; }
    run start_certbot_nginx
    [ "$status" -ne 0 ]
    ! grep -Eq '^(stop|rm|run)$' "$trace"
}

@test "the issued certificate uses the same challenge directory as the running proxy" {
    source "$PROJECT_ROOT/lib/letsencrypt_integration.sh"
    source "$PROJECT_ROOT/lib/nginx_stream_generator.sh"
    run generate_nginx_config proxy.example.test
    [ "$status" -eq 0 ]
    local root
    root=$(sed -n '/location \/.well-known\/acme-challenge\//,+1s/.*root \([^;]*\);/\1/p' <<< "$output")
    [ "$root" = "$CERTBOT_WEBROOT" ]
}

@test "new service-mode images delegate renewal to the host" {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir "$bin"
    printf '#!/bin/sh\ntouch "$TRACE"\n' > "$bin/certbot"
    printf '#!/bin/sh\nkill -TERM "$PPID"\n' > "$bin/sleep"
    chmod +x "$bin/"*
    run env FT_SERVICE_MODE=proxy TRACE="$bin/called" PATH="$bin:$PATH" sh "$PROJECT_ROOT/docker/familytraffic/certbot-renew.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$bin/called" ]
}

@test "renewal opens only time-limited TCP 80 rules, then removes the same rules" {
    source "$PROJECT_ROOT/scripts/familytraffic-acme-hook"
    state="$BATS_TEST_TMPDIR/until"
    trace="$BATS_TEST_TMPDIR/rules"
    ufw() { echo 'Status: active'; }
    iptables() { echo "ipv4 $*" >> "$trace"; }
    ip6tables() { echo "ipv6 $*" >> "$trace"; }
    acme_hook_main open
    local deadline
    deadline=$(cat "$state")
    acme_hook_main close
    [ ! -e "$state" ]
    for family in ipv4 ipv6; do
        local chain=ufw-user-input
        [[ $family == ipv4 ]] || chain=ufw6-user-input
        for op in -A -D; do
            grep -Fqx "$family -w $op $chain -p tcp --dport 80 -m time --datestop $deadline -m comment --comment familytraffic-http01 -j ACCEPT" "$trace"
        done
    done
    acme_hook_main close
    [ "$(grep -c -- ' -D ' "$trace")" -eq 2 ]
}

@test "a partial IPv6 hook failure removes the temporary IPv4 grant" {
    source "$PROJECT_ROOT/scripts/familytraffic-acme-hook"
    state="$BATS_TEST_TMPDIR/until"
    trace="$BATS_TEST_TMPDIR/rules"
    ufw() { echo 'Status: active'; }
    iptables() { echo "$*" >> "$trace"; }
    ip6tables() { [[ $2 == -S ]]; }
    run acme_hook_main open
    [ "$status" -ne 0 ]
    grep -q -- '-D ufw-user-input' "$trace"
    [ ! -e "$state" ]
}
