# CLI Tools

## Overview

familyTraffic ships four root-only CLI entry points installed to `$PATH`: `familytraffic` (the main management tool for users, transports, proxy assignments, firewall, and service ops), `familytraffic-mtproxy` (MTProxy/mtg v2 lifecycle and secrets), `familytraffic-external-proxy` (upstream SOCKS5/HTTP proxy chains), and `familytraffic-cert-renew` (a certbot deploy-hook for certificate renewal). All require `sudo`.

## familytraffic (main CLI)

The primary management tool (`scripts/familytraffic`). Every command requires root and is dispatched from a `case` block; with no arguments it prints usage. It sources lib modules on demand and operates the single host-network container. See [[architecture]], [[services]], and [[installation]].

User management ([[user-management]]): `add-user <username>` (aliases `adduser`), `remove-user <username>` (`rmuser`, `deleteuser`), `list-users` (`ls`, `users`), `show-user <username>` (`show`, `user`), `regenerate <username>` (`regen`). The XTLS Vision migration safety-net is `migrate-vision`.

Tier 2 transports ([[transports]]): `add-transport <type> <subdomain>` (types `ws`, `xhttp`, `grpc`), `list-transports`, `remove-transport <type>` — handled via `transport_manager.sh`.

Per-user external proxy ([[proxy-chains]]): `set-proxy <user> <id|none>`, `unset-proxy <username>` (alias for `set-proxy <user> none`), `show-proxy <username>`, `list-proxy-assignments`.

Proxy IP whitelist (xray-level): `show-proxy-ips`, `set-proxy-ips <ips>`, `add-proxy-ip <ip>`, `remove-proxy-ip <ip>`, `reset-proxy-ips`. UFW host-level whitelist ([[security]]): `show-ufw-ips`, `add-ufw-ip <ip>`, `remove-ufw-ip <ip>`, `reset-ufw-ips`.

No-TLS plaintext proxy ports (cleartext SOCKS5 1081 / HTTP 8119, regenerates `nginx.conf`): `enable-notls`, `disable-notls`.

Service ops ([[services]], [[docker]]): `status` (container + supervisorctl + routing + proxy summary), `start`/`stop`/`restart` (via `docker compose`), `logs [xray|nginx|all]`, `test` (runs `xray -test`). Maintenance/info: `update` (`upgrade` — currently prints manual steps), `backup` (tars config/data/.env), `info`, `help`. Security testing ([[testing]], [[security]]): `test-security [--quick|--skip-pcap|--verbose|--dev-mode]`, delegating to `lib/security_tests.sh`.

## familytraffic-mtproxy

MTProxy management CLI (`scripts/familytraffic-mtproxy`, v7.0 — mtg v2 under supervisord). Runs as root; `setup` and `help` work pre-install, all other verbs require an existing install. It sources `mtproxy_manager.sh`, `mtproxy_secret_manager.sh`, and `nginx_stream_generator.sh`. See [[mtproxy]].

Setup and control: `setup [--fake-domain <site>]` (generates `mtg.toml`, opens UFW 2053, regenerates `nginx.conf` with cloak-port 4443, enables mtg autostart; `--domain` is a deprecated alias for `--fake-domain`); `disable` (stops mtg, removes autostart, closes UFW, drops cloak-port).

Secret management: `add-secret [--type standard|dd|ee] [--fake-domain <site>] [--user <name>]` (default type `ee` Fake-TLS, regenerates `mtg.toml` and restarts mtg if running), `list-secrets`, `remove-secret <secret|username>`.

Process management (via supervisorctl): `start`, `stop`, `restart`, `status`. Monitoring: `logs [--tail <n>] [--follow|-f]`, `stats` (mtg v2 exposes no HTTP stats — points to status/logs). Legacy client helpers kept for compatibility: `show-config <username>`, `generate-qr <username>`. Plus `help` (`--help`, `-h`).

## familytraffic-external-proxy

Upstream proxy chain manager (`scripts/familytraffic-external-proxy`, v5.23). Routes traffic `Client → Nginx → Xray → External Proxy → Internet`. Runs as root, requires `/opt/familytraffic`, and sources `external_proxy_manager.sh` and `xray_routing_manager.sh`. See [[proxy-chains]].

Commands: `add` (6-step interactive wizard: pick type socks5/socks5s/http/https, address+port, TLS SNI + allow-insecure, optional auth, summary, confirm — then tests connectivity and optionally activates/enables), `list`, `show <proxy-id>`, `switch <proxy-id>` (activate + update xray outbounds), `update <proxy-id>` (edit address/port/username/password), `remove <proxy-id>`, `test <proxy-id>`, `enable` / `disable` (toggle routing; both auto-restart xray via `supervisorctl restart xray`), `status`, and `help` (`-h`, `--help`).

## familytraffic-cert-renew

Certbot deploy-hook for Let's Encrypt renewal (`scripts/familytraffic-cert-renew`), installed at `/usr/local/bin/familytraffic-cert-renew`. Not invoked interactively — certbot calls it via `--deploy-hook` and passes the renewed names in `$RENEWED_DOMAINS` (the script aborts if unset). See [[certificates]].

It runs phased: pre-renewal validation (cert files, `nginx -t`, container health, disk space, write perms), then a zero-downtime `supervisorctl signal SIGHUP nginx`, an xray restart, and metrics output. Features retry-with-exponential-backoff, per-domain graceful degradation, combined.pem backup/rollback, and structured severity logging. Tunable via env vars: `FAMILYTRAFFIC_RENEW_VERBOSE`, `LOG_LEVEL`, `RETRY_MAX_ATTEMPTS`, `RETRY_INITIAL_DELAY`, `RETRY_MAX_DELAY`. Logs to `/opt/familytraffic/logs/certbot-renew.log`; metrics to `certbot-renew-metrics.json`.
