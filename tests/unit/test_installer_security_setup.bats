#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export TRACE="$BATS_TEST_TMPDIR/trace"
}

@test "inactive firewall permits selected SSH source and current session before enabling" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        state=inactive
        ufw() { printf "%s\n" "$*" >> "$TRACE"; case "$*" in status) echo "Status: $state";; "--force enable") state=active;; esac; }
        export SSH_CONNECTION="198.51.100.7 50000 192.0.2.1 22"
        configure_install_firewall 203.0.113.0/24
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$(cat "$TRACE")" == *"allow from 203.0.113.0/24 to any port 22 proto tcp"* ]]
    [[ "$(cat "$TRACE")" == *"allow from 198.51.100.7 to any port 22 proto tcp"* ]]
    [ "$(tail -2 "$TRACE" | head -1)" = "--force enable" ]
    ! grep -Eq 'reset|delete|default' "$TRACE"
}

@test "empty SSH source allows any address and active firewall is preserved" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        ufw() { printf "%s\n" "$*" >> "$TRACE"; [[ "$1" != status ]] || echo "Status: active"; }
        configure_install_firewall ""
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    grep -qx 'insert 1 allow 22/tcp' "$TRACE"
    ! grep -Eq 'enable|reset|delete|default' "$TRACE"
}

@test "invalid SSH source stops before firewall mutation" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        ufw() { echo "$*" >> "$TRACE"; }
        configure_install_firewall "not-an-address"
    ' _ "$PROJECT_ROOT"
    [ "$status" -ne 0 ]
    [ ! -e "$TRACE" ]
}

@test "SSH rule failure never enables firewall" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        ufw() { echo "$*" >> "$TRACE"; return 1; }
        configure_install_firewall ""
    ' _ "$PROJECT_ROOT"
    [ "$status" -ne 0 ]
    ! grep -q enable "$TRACE"
}

@test "SSH source prompt accepts empty input and validates retry" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        prompt_ssh_source <<< $'\''invalid\n192.0.2.7\n'\''
        [[ "$SSH_ALLOW_FROM" == 192.0.2.7 ]]
        prompt_ssh_source <<< ""
        [[ -z "$SSH_ALLOW_FROM" ]]
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
}

@test "later installer firewall setup never deletes existing operator rules" {
    run bash -c '
        set -e
        source <(sed -n "/^configure_ufw()/,/^}/p" "$1/lib/orchestrator.sh")
        UFW_AFTER_RULES="$2/after.rules" UFW_BACKUP_DIR="$2/backup" DOCKER_SUBNET=172.20.0.0/16
        CYAN="" NC="" YELLOW="" GREEN=""
        ufw() { echo "$*" >> "$TRACE"; [[ "$1" != status ]] || printf "Status: active\n[ 1] 8443/tcp ALLOW IN 192.0.2.7\n[ 2] 9443/tcp ALLOW IN 192.0.2.7\n"; }
        configure_ufw || exit $?
    ' _ "$PROJECT_ROOT" "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    ! grep -q delete "$TRACE"
}

@test "sudo without SSH_CONNECTION still preserves the detected management source" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        unset SSH_CONNECTION
        current_ssh_connection() { echo "198.51.100.7 50000 192.0.2.1 22"; }
        ufw() { echo "$*" >> "$TRACE"; [[ "$1" != status ]] || echo "Status: active"; }
        configure_install_firewall 203.0.113.7
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    grep -qx 'insert 1 allow from 198.51.100.7 to any port 22 proto tcp' "$TRACE"
}

@test "preexisting SSH deny never precedes management permission on activation" {
    run bash -c '
        set -e
        source "$1/lib/installer_security.sh"
        verify_ssh_firewall_rules() { :; }
        current_ssh_connection() { echo "198.51.100.7 50000 192.0.2.1 22"; }
        first=deny
        state=inactive
        ufw() {
            case "$*" in
                "insert 1 allow"*) first=allow ;;
                "--force enable") echo "$first" > "$TRACE"; state=active ;;
                status) echo "Status: $state" ;;
            esac
        }
        configure_install_firewall 198.51.100.7
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [ "$(cat "$TRACE")" = allow ]
}
