# Installation

## Overview

`install.sh` is the root entry point: a 10-step, root-only orchestrator that migrates legacy `/opt/vless` installs, sources `lib/` modules, detects and validates the OS, auto-installs dependencies (with APT-lock handling), finds free ports and Docker subnets, runs an interactive wizard (Reality destination, subnet, proxy mode, DNS, TLS domain/email), detects and optionally backs up/cleans previous installs, then deploys into `/opt/familytraffic`. See [[architecture]] and [[docker]] for what gets deployed.

## Entry Point and Step Flow

`install.sh` must run as root (exit code 2 otherwise) from the project directory. It declares `FT_VERSION=5.33.0`, derives `GHCR_IMAGE` from the git remote (overridable), defaults `FT_IMAGE_TAG=latest`, and runs `main()` as a 10-step pipeline (`TOTAL_STEPS=10`) guarded by an EXIT trap that prints retry instructions on failure.

The numbered steps are: (1) root check, (2) `detect_os`, (3) `validate_os`, (4) `check_dependencies`, (5) `install_dependencies`, (6) `detect_old_installation`, (7) `collect_parameters`, (8) `orchestrate_installation` (creates `/opt/familytraffic`, copies files, deploys containers), (9) `verify_installation`, (10) sudoers instructions. Between steps 7 and 8 it optionally acquires a TLS certificate (step 7.5) and, after step 9, writes `.version`, offers optional [[mtproxy]] setup, and prints the final banner. Non-interactive automation is driven by env vars: `FT_AUTO_CLEANUP` (1/2/3), `FT_CONFIRM_CLEANUP=yes`, `FT_AUTO_INSTALL_DEPS=yes`, `FT_AUTO_KILL_SAFE_LOCKS=yes`, `FT_ENABLE_MTPROXY`.

## Module Loading

`source_libraries()` requires `lib/` to exist and sources a fixed module list, aborting (exit 1) if any is missing: `os_detection.sh`, `dependencies.sh`, `old_install_detect.sh`, `interactive_params.sh`, `sudoers_info.sh`, `orchestrator.sh`, `verification.sh`, `security_hardening.sh`, `certbot_setup.sh`. After sourcing `orchestrator.sh` it exports `CONFIG_DIR` and `LOG_DIR` (from `LOGS_DIR`) for later modules. Modules guard color variables and `set -euo pipefail` with `[[ -z ... ]]` / `[[ ! -o pipefail ]]` checks so they can be safely re-sourced.

## OS Detection

`lib/os_detection.sh` parses `/etc/os-release` with `grep`/`cut` (not by sourcing it — sourcing collides with readonly vars like `VERSION`), setting exported `OS_NAME`, `OS_VERSION`, `OS_VERSION_CODENAME`, `OS_ID`. Missing or unreadable files, or incomplete fields, abort with exit 1; an empty codename falls back to `unknown`.

`validate_os()` allows only Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble) and Debian 10 (buster), 11 (bullseye), 12 (bookworm). A mismatched codename for an otherwise-supported version is a non-fatal warning; any other OS/version prints the supported list and fails. `get_package_manager()` then sets `PKG_MANAGER`, preferring `apt` and falling back to `apt-get`.

## Dependencies

`lib/dependencies.sh` defines `REQUIRED_PACKAGES` (docker.io, docker-compose-plugin, ufw, jq, qrencode, curl, openssl, fail2ban, logrotate, certbot, dnsutils, tcpdump, nmap) and `OPTIONAL_PACKAGES` (netcat-openbsd, tshark). `check_dependencies()` maps each package to a command, enforces minimum versions via `version_compare` (Docker ≥ 20.10, docker compose ≥ 1.29, jq ≥ 1.5), and prompts to proceed (30 s timeout, default yes; skipped when `FT_AUTO_INSTALL_DEPS=yes`).

`install_dependencies()` runs `apt update` with up to 5 retries. On failure it calls `check_apt_locks()`, which inspects the four dpkg/apt lock files via `fuser` and classifies holding processes through `classify_apt_process()` as SAFE (apt update/search, apt-cache, recent unattended-upgrade), DANGER (dpkg install/configure), or CAUTION. `kill_safe_apt_processes()` only auto-kills SAFE ones; otherwise `diagnose_apt_locks()` prints remediation and the user chooses wait/auto-kill/kill-all/cancel. `setup_docker_repository()` adds Docker's official GPG key and APT source (needed for docker-compose-plugin) before package installs proceed one by one with per-package verification, Docker service enablement (`start_docker_service`), and fallbacks (docker-compose standalone, netcat variants). `validate_docker()` runs a 6-check diagnostic (version, socket, group, daemon, hello-world run, compose version). All installs use `DEBIAN_FRONTEND=noninteractive`. See [[docker]].

## Network Parameters

`lib/network_params.sh` provides non-interactive auto-generation of `VLESS_PORT` and `DOCKER_SUBNET` (the interactive wizard in `interactive_params.sh` is what `install.sh` actually calls). `generate_vless_port()` tries 443, then 8443, then a common-port list (2053/2083/2087/2096), then up to 100 random ports in 10000–60000, using `is_port_available()` (ss → netstat → lsof fallback). `generate_docker_subnet()` tries `172.20.0.0/16`, then scans 172.16–31, then 10.0–10, then 192.168.100–200, then random, using `is_subnet_available()` which inspects existing Docker network subnets. `validate_subnet()` and `validate_port()` enforce CIDR (/1–32) and 1–65535 ranges.

## Interactive Setup

`lib/interactive_params.sh` runs `collect_parameters()`: it hardcodes `VLESS_PORT=8443` (Xray internal; nginx fronts 443 per the [[architecture]]), then walks through destination, subnet, proxy, optional TLS, and a confirmation summary. `select_destination_site()` offers four predefined Reality targets (google/microsoft/apple/cloudflare:443) or a custom `host:port`, validating each with `validate_destination()` (DNS via `getent`, TLS reachability and TLS 1.3 probe via `openssl s_client`, 10 s timeout; TLS 1.3 is a soft check). `select_docker_subnet()` scans existing Docker networks (`scan_docker_networks`) and proposes the default or a free 172.x subnet (`find_free_subnet`).

`prompt_enable_public_proxy()` chooses VLESS-only (default) vs. public proxy mode; enabling it requires a double confirmation and then a TLS choice (`ENABLE_PROXY_TLS`, default yes → socks5s/https on 1080/8118; no → plaintext) and an optional no-TLS ports prompt (`PROXY_NOTLS_ENABLED` → 1081/8119). When public proxy + TLS are on, `prompt_domain_email()` collects `DOMAIN` and `EMAIL`, validating domain format and DNS A-record against `get_server_public_ip()` (curl ifconfig.me/icanhazip/ipify or dig OpenDNS). After destination selection, `detect_optimal_dns()` benchmarks ~12 DNS servers (Cloudflare, Google, Quad9, OpenDNS, several Yandex modes, plus system DNS) with `dig` query times, and `prompt_dns_selection()` lets the user pick up to 3 (or auto-select the fastest), setting `DETECTED_DNS_PRIMARY/SECONDARY/TERTIARY`. See [[proxy-chains]] and [[security]] for proxy/hardening details and [[certificates]] for TLS acquisition.

## TLS Certificate Acquisition

Step 7.5 in `install.sh` runs only when `ENABLE_PUBLIC_PROXY=true` and `ENABLE_PROXY_TLS=true`. It performs a 6-stage sequence from `certbot_setup.sh`: `validate_domain_dns`, `install_certbot`, `open_port_80_for_acme`, `obtain_certificate "$DOMAIN" "$EMAIL"`, `close_port_80_after_acme`, and `setup_renewal_cron`. It then installs the `familytraffic-cert-renew` deploy hook to `/usr/local/bin` and writes `/etc/logrotate.d/familytraffic-certbot-renew` (renewal log 30 days, metrics 12 weeks). The resulting cert lives at `/etc/letsencrypt/live/$DOMAIN/fullchain.pem`. See [[certificates]].

## Old-Install Detection

`lib/old_install_detect.sh` runs `detect_old_installation()`, a 7-level scan that populates `OLD_CONTAINERS`, `OLD_NETWORKS`, `OLD_VOLUMES`, `OLD_UFW_RULES`, `OLD_SERVICES`, `OLD_SYMLINKS` and sets `OLD_INSTALL_FOUND=true` if any finding exists. The levels are: (1) Docker containers named `vless`/`xray`/`nginx`-with-vless, (2) Docker networks `vless*` (excluding bridge/host/none), (3) Docker volumes `vless*`, (4) the `/opt/familytraffic` directory (flagging `users.json`, `xray_config.json`, `docker-compose.yml`), (5) UFW rules matching `443`/`vless`, (6) systemd unit files matching `vless`, (7) `/usr/local/bin/vless-*` symlinks.

When something is found, `install.sh` shows `display_detection_summary()` and prompts (60 s timeout, default 3 = safe exit): 1 = backup then cleanup, 2 = cleanup without backup, 3 = skip and exit. `backup_old_installation()` writes a timestamped `/opt/familytraffic_backup_<ts>` (copying the install dir, exporting container/network `docker inspect` JSON, calling `backup_ufw_rules()` into `/tmp/familytraffic_ufw_backup_<ts>`, and a metadata file). `cleanup_old_installation()` requires typed `yes` confirmation (or `FT_CONFIRM_CLEANUP=yes`) before removing containers, networks, volumes, the directory, services, and symlinks (UFW rules are flagged for manual removal). `restore_from_backup()` reverses a backup. See [[services]] and [[security]].

## Migration / Rename

`lib/migrate_rename.sh` handles the project rename from `/opt/vless` to `/opt/familytraffic` (v5.33). `install.sh` sources and runs `migrate_rename()` early — before module loading — but only when `/opt/familytraffic` exists and is not a symlink; the module itself decides the real action by inspecting both paths. Case 1 (old dir exists, new dir does not, old is not a symlink): atomic `mv /opt/vless /opt/familytraffic` followed by a backwards-compat symlink `ln -s /opt/familytraffic /opt/vless`. Case 2 (old path already a symlink): migration was done before, no-op. Case 3 (both real directories): it refuses to migrate and prints a hint to `rm -rf /opt/vless`. Case 4 (neither exists): fresh install, nothing to do. `mv` is used instead of `cp -a + rm -rf` so an interruption leaves no partial state.
