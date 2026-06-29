# Testing

## Overview

familyTraffic ships a BATS-based test suite under `tests/`: pure-Bash unit tests (validation, logger, OS detection — no Docker), integration tests that need root and a deployed container, and performance/timing tests. A shared `test_helper.bash` provides `setup_test_env`, command mocks, custom assertions, and skip guards. Standalone shell scripts cover security and proxy-URI behavior. This page lists each suite and how to run it.

## Unit Tests (BATS)

Unit tests live in `tests/unit/` and run with no Docker or container — they source `lib/` modules directly and exercise them in a temp sandbox. Each file `load ../test_helper`, then `setup` calls `setup_test_env` and `teardown` calls `teardown_test_env`.

`test_validation.bats` exercises `lib/validation.sh`: `validate_username`, `validate_port`, `validate_ip`, `validate_subnet`, `validate_uuid`, `validate_domain`, `validate_path` — asserting exit code 0 for valid input and 1 for empty/malformed/out-of-range input. See [[user-management#Validation]].

`test_logger.bats` checks `lib/logger.sh` (`log_info`/`log_error`/`log_warn`/`log_success`/`log_debug`), verifying level labels, message passthrough, `DEBUG`-gated debug output, the `YYYY-MM-DD HH:MM:SS` timestamp, and handling of empty/special/multiline messages.

`test_os_detection.bats` checks `lib/os_detection.sh` (`detect_os`, `is_supported_os`, `get_package_manager`, `check_system_requirements`, `detect_architecture`). Some cases mock `OS_NAME`/`OS_VERSION`; others guard with `skip_if_not_root` or skip when not on the matching `uname -m` arch.

## Integration Tests

Integration tests need root and a deployed container; most are gated and will skip in a bare checkout. See [[docker]] and [[architecture]] for the container they target, and [[installation]] for getting one running.

`tests/integration/test_user_workflow.bats` is the BATS integration file: `setup` calls `skip_if_not_root` and builds a mock install (`create_mock_xray_config`, `create_mock_users_json`) under the temp dir. It covers the user lifecycle (`create_user`, `remove_user`, UUID generation, client dir, concurrent creation), but every case currently `skip`s with "Requires full system setup".

Several standalone shell scripts target a live `/opt/familytraffic` deployment. `test_security.sh` (root + `nmap`/`jq`/`curl`/`ufw`) checks open ports, 32-char password strength, and UFW rate limiting. `test_public_proxy.sh` (root + `curl`/`jq`/`fail2ban-client`/`docker`/`ufw`) tests SOCKS5/HTTP access, fail2ban, config, firewall, and Docker healthchecks ([[security]], [[proxy-chains]]). `test_mtproxy_cloak.sh` verifies active-probing protection on cloak-port 4443 and that port 2053 leaks no proxy banner; it auto-enables `DEV_MODE` when `/opt/familytraffic` is absent ([[mtproxy]]). `test_encryption_security.sh` is a stub that redirects to `lib/security_tests.sh`, now run via `sudo familytraffic test-security [--quick|--verbose|--skip-pcap]` ([[cli-tools]]).

`tests/test_proxy_uri_generation.sh` is self-contained (no container): it sources `lib/user_management.sh` in a temp `VLESS_HOME` and asserts the export helpers (`export_http_config`, `export_socks5_config`, `export_vscode_config`, `export_docker_config`, `export_bash_config`) emit `http://`/`socks5://` in localhost mode and `https://`/`socks5s://` in public-proxy mode.

## Performance Tests

`tests/performance/test_performance.bats` holds timing assertions: user creation < 5s, QR generation < 2s, status display < 3s, security audit < 10s, 1000-line log filtering < 2s, and permission hardening < 5s. Most cases `skip` with "Requires full system setup" (and `skip_if_command_missing qrencode` for QR). The one always-on case sources `lib/validation.sh` and asserts 1000 `validate_port` calls finish in under 1 second.

## Test Helpers

`tests/test_helper.bash` is loaded by every BATS file (`load ../test_helper`). It exports project paths (`PROJECT_ROOT`, `LIB_DIR`, `TESTS_DIR`, `TEMP_DIR`) and a `BATS_TEST_TIMEOUT` of 30s, and exports all helper functions for use inside tests.

Environment: `setup_test_env` makes `TEMP_DIR`, a mock install at `$TEMP_DIR/opt/vless` with `config/data/keys/logs/backups` subdirs, an empty `users.json`, and `0750` perms; `teardown_test_env` removes `TEMP_DIR`. `mock_command <name> <output>` writes a fake executable into `TEMP_DIR` and prepends it to `PATH`. `create_mock_xray_config` and `create_mock_users_json <file> [count]` generate fixtures; `wait_for_condition <timeout> <cmd>` polls.

Assertions and guards: `assert_file_exists`, `assert_dir_exists`, `assert_contains`, `assert_success`, `assert_failure`, plus `skip_if_not_root` and `skip_if_command_missing <cmd>` for environment-dependent cases.

## Running Tests

Tests use the [BATS](https://github.com/bats-core/bats-core) runner. Run the full unit suite from the `tests/` dir, or point BATS at a single file or directory by path.

```bash
# All unit tests
cd tests && bats unit/

# A single unit file
bats tests/unit/test_validation.bats
bats tests/unit/test_logger.bats
bats tests/unit/test_os_detection.bats

# Integration (need root + deployed container; most cases skip otherwise)
bats tests/integration/test_user_workflow.bats
sudo bash tests/integration/test_mtproxy_cloak.sh

# Performance
bats tests/performance/test_performance.bats

# Standalone proxy-URI script (no container)
bash tests/test_proxy_uri_generation.sh
```

Integration shell scripts exit `0` (pass), `1` (fail), `2` (prerequisites not met), and `3` (critical security issues, for the security suite). The encryption/security tests are invoked through the CLI: `sudo familytraffic test-security` ([[cli-tools]], [[security]]).
