#!/usr/bin/env bats

load '../test_helper'

@test "TLS installation delegates ACME lifecycle to certificate acquisition" {
    run bash -c '
        source <(sed '\''$d'\'' "$1")
        trap - EXIT

        check_root() { :; }
        source_libraries() { :; }
        detect_os() { :; }
        validate_os() { :; }
        get_package_manager() { :; }
        check_dependencies() { return 0; }
        install_dependencies() { :; }
        detect_old_installation() { OLD_INSTALL_FOUND=false; }
        collect_parameters() {
            ENABLE_PUBLIC_PROXY=true
            ENABLE_PROXY_TLS=true
            DOMAIN=ft.example.com
            EMAIL=ops@example.com
        }
        get_server_public_ip() { printf "%s\n" "203.0.113.10"; }
        validate_domain_dns() { return 0; }
        install_certbot() { return 0; }
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
