# Services

## Overview

Runtime and install-time service plumbing. The orchestrator wires modules to build the install tree and deploy containers; service operations cover start/stop/restart/reload and status; container management ensures the container is healthy; common helpers do inode-safe writes; verification runs post-install checks. See [[architecture#Process Supervision]].

## Orchestrator

`lib/orchestrator.sh` defines `orchestrate_installation()`, the ordered driver called by `install.sh`.

It sources `nginx_stream_generator.sh`, `external_proxy_manager.sh`, and `xray_routing_manager.sh`, then runs a numbered pipeline. Each step short-circuits with `return 1` on failure, so the install aborts at the first error.

## Installation Pipeline

`orchestrate_installation()` runs steps in a fixed order, failing fast at the first error.

It creates the `/opt/familytraffic` tree (`create_directory_structure`), sets log-dir permissions, generates X25519 Reality keys (`generate_reality_keys`) and a 16-hex Short ID (`generate_short_id`), writes `xray_config.json` (`create_xray_config`), and seeds `users.json`, the proxy IP whitelist, and the external-proxy DB. It then generates nginx config, copies `docker-compose.yml`, writes `.env`, configures fail2ban/UFW, and runs `set_permissions` → `verify_file_permissions` → `deploy_containers` → `install_cli_tools` → `setup_xray_logrotate`. Permissions are set BEFORE deploy because Docker bind-mounts capture file modes at mount time.

## Config Generation

The orchestrator emits all runtime config files, validating each before use.

`create_xray_config` builds `xray_config.json` from `PRIVATE_KEY`, `SHORT_ID`, and the Reality `dest`/port, optionally appending SOCKS5 (10800), HTTP (18118), and Tier 2 WS/XHTTP/gRPC (8444–8446) inbounds via `generate_*_inbound_json`, validates JSON with `jq empty`, and runs `xray -test`. `generate_nginx_config_wrapper` delegates to `nginx_stream_generator.sh` for SNI routing. `create_env_file` writes `.env` (`GHCR_IMAGE`, `FT_IMAGE_TAG`, `DOMAIN`, proxy flags, `FT_DEBUG`). See [[transports]], [[proxy-chains]], and [[security]].

## Container Deployment

`deploy_containers()` runs pre-flight file checks, then pulls and starts the container via `docker compose`.

It verifies critical files (xray/nginx configs, compose, `.env`, keys), `cd`s to `/opt/familytraffic`, and runs `docker compose pull` + `up -d`. It then inspects the single `familytraffic` container's `.State.Status` and `.State.Health.Status`, and scans `docker logs` for `bind() to ... failed` or `nginx: [emerg]`, failing the deploy if either appears. The single-container model is detailed in [[docker]].

## Service Operations

`lib/service_operations.sh` manages the running service via `docker-compose` (start, stop, restart, reload).

`start_service` brings the stack up and waits for health; `stop_service` does a graceful `down --timeout 30`; `restart_service` chains stop+start. `reload_xray` sends `HUP` to the xray service for a live config reload, falling back to a container restart if the signal fails. `is_service_running` checks both `xray` and `nginx` service handles. These functions back the CLI service commands in [[cli-tools]].

## Status & Logs

`display_service_status` renders a status panel; log helpers wrap `docker-compose logs` with level filtering.

The panel shows per-container status/uptime/health (`get_container_status`, `get_container_uptime`, `format_uptime`, `get_container_health`), network info from `.env`, proxy inbounds parsed from `xray_config.json`, and the user count from `users.json`. Log helpers (`display_xray_logs`, `display_nginx_logs`, `display_all_logs`, `follow_logs`, `export_logs`) pipe through `filter_logs_by_level` for ERROR/WARN/INFO/DEBUG filtering.

## Update & Backup

`update_xray` and `update_system` pull fresh images and force-recreate containers while preserving subnet, port, and keys.

Both call `create_config_backup` first, which snapshots `.env`, `config/`, and `docker-compose.yml` into a timestamped dir under `backups/` with a manifest, keeping the last 10 (`cleanup_old_backups`). On a failed recreate or health timeout, `restore_config_backup` reverts to the newest backup and restarts the service.

## Container Management

`lib/container_management.sh` provides reusable readiness primitives used before mutating operations.

`is_container_running` matches an exact name in `docker ps`; `ensure_container_running` starts a stopped container and polls until running; `ensure_all_containers_running` checks the single `familytraffic` container and prints supervisord/log troubleshooting on failure. `retry_operation` retries any command with exponential backoff (2s, 4s, 8s…), and `wait_for_container_healthy` polls the Docker healthcheck, returning early if none is configured. See [[docker]].

## Common Helpers

`lib/common.sh` holds `write_preserving_inode "$src" "$dst"`, which copies content with `cat src > dst` rather than `mv`.

Docker file bind-mounts are pinned to the target file's inode, so replacing the directory entry (as `mv` does) would leave the container reading stale content. The orchestrator uses it for atomic `users.json` and `proxy_allowed_ips.json` updates after `jq` edits.

## Verification

`lib/verification.sh` runs `verify_installation()`, aggregating results into `VERIFICATION_PASSED`/`VERIFICATION_ERRORS` and exiting non-zero on any failure.

Checks cover the directory tree and required files, sensitive permissions (keys/data dirs 700, `.env`/keys/`users.json` 600, root-owned), `network_mode: host`, container status/health, Xray config (`jq` + `xray -test`, protocol/security/key/dest), TLS for public proxy (`validate_mandatory_tls`), UFW rules, container internet/DNS reachability, and host port listening (443/1080/8118). `display_verification_summary` prints pass/fail with next steps. See [[security]] and [[certificates]].
