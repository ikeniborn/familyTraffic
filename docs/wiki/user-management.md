# User Management

## Overview

`lib/user_management.sh` is the VLESS user lifecycle engine: user CRUD, UUID/shortId/proxy-password generation, live-reloadable `users.json` DB, connection-URI and QR generation, and input validation. See [[cli-tools]], [[architecture#Host Paths]].

It owns every account mutation: it writes `users.json` under an exclusive `flock`, mirrors changes into `xray_config.json`, reloads xray with SIGHUP, and renders connection URIs plus QR codes and exported config files. Input is validated before any write.

## Users Database

`users.json` at `/opt/familytraffic/data/users.json` is the source of truth for accounts — a `.users[]` array bind-mounted into the container (see [[architecture#Host Paths]]) and live-reloaded by xray on SIGHUP.

Each entry carries `username`, `uuid`, `shortId`, `proxy_password`, `fingerprint`, `external_proxy_id`, `connection_type` (`vpn`/`proxy`/`both`), optional MTProxy fields (`mtproxy_secret`, `mtproxy_secret_type`, `mtproxy_domain`), plus `created` (`date -Iseconds`) and `created_timestamp`. All writes go through `add_user_to_json` / `remove_user_from_json` (and the migration/reset helpers) under `flock -x 200` on `/var/lock/familytraffic_users.lock`: they write a `.tmp.$$` file, validate it with `jq empty`, then commit with `write_preserving_inode` (preserving the inode is mandatory for Docker bind mounts) and `chmod 600`. `migrate_users_schema_v525` lazily backfills `connection_type="both"` on legacy records.

## User CRUD

`create_user`, `remove_user`, `list_users`, `user_exists`, and `get_user_info` are the lifecycle entry points, reached via the [[cli-tools]] verbs `create`/`remove`/`list`.

`create_user` validates the username, rejects duplicates, then prompts interactively for connection type, TLS fingerprint, optional external proxy, and optional MTProxy secret. It provisions in order: generate UUID + shortId + proxy password, create the per-user dir under `data/clients/`, append to `users.json`, add the client to xray (`add_client_to_xray`), register SOCKS5/HTTP proxy accounts, apply per-user routing, reload xray, and finally emit the VLESS URI/QR and proxy config files; failures roll back (remove from JSON, delete the dir). `remove_user` reverses this — strip the client and its shortId from xray, remove proxy accounts, reload, then delete the JSON record and the client directory. Steps are skipped by `connection_type` (proxy-only users get no UUID/xray client; vpn-only users get no proxy account).

## UUID & Identity Generation

VPN identities use three generated secrets: a UUID v4, a per-user Reality shortId, and a proxy password — produced by `generate_uuid`, `generate_short_id`, and `generate_proxy_password`.

`generate_uuid` prefers `uuidgen`, then `/proc/sys/kernel/random/uuid`, with a `/dev/urandom`-based manual fallback that sets the version/variant bits. `generate_short_id` produces an 8-byte (16 hex char) shortId via `openssl rand -hex 8`; each user's shortId is added to (and, on removal, pruned from) `realitySettings.shortIds` in xray. `generate_proxy_password` produces a 16-byte (32 hex char) password via `openssl rand -hex 16` for SOCKS5/HTTP auth. UUIDs become xray clients with `flow=xtls-rprx-vision` and `email=<user>@vless.local`. See [[security]].

## Xray Sync & SIGHUP Reload

After any DB change, the xray config and the running process are kept in sync, then xray is signalled to reload — without disturbing nginx or certbot. See [[services]], [[proxy-chains]].

`add_client_to_xray` / `remove_client_from_xray` edit `inbounds[0].settings.clients` and the Reality `shortIds` array in `/opt/familytraffic/config/xray_config.json`, backing up first, validating with `jq empty` and (if the container is running) a throwaway `xray -test` run, then committing via `write_preserving_inode`. `update_proxy_accounts` / `remove_proxy_accounts` / `rebuild_proxy_accounts_from_users_json` keep the SOCKS5 and HTTP inbound `accounts` arrays aligned with `users.json` (the rebuild guards against an accidentally open HTTP proxy). `reload_xray` then signals only the xray process — `supervisorctl signal SIGHUP xray` (live reload of clients without dropping nginx/certbot), falling back to `supervisorctl restart xray`, then `pkill -HUP -x xray`.

## Connection URIs & QR Codes

`generate_vless_uri` builds the Reality URI and `generate_transport_uri` builds the Tier 2 variants; `lib/qr_generator.sh` renders QR codes and exports per-user config files into `data/clients/<user>/`. See [[transports]].

The Reality URI is `vless://MASKING@IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=…&fp=…&pbk=…&sid=…&type=tcp#username`, pulling the public key from `keys/public.key`, the user's own shortId and fingerprint from `users.json` (falling back to server defaults for legacy users), and the SNI from `realitySettings.serverNames[0]`. `generate_transport_uri` emits `ws`/`xhttp`(splithttp)/`grpc` URIs over `security=tls` on the matching subdomain. `lib/qr_generator.sh` renders an ANSI QR in the terminal plus a 400×400 PNG (`qrencode -s 10`), and `export_connection_config` writes `vless_uri.txt`, `connection_info.txt`, and `config.json` (all `chmod 600`). Proxy users additionally get `socks5_config.txt`, `http_config.txt`, and VSCode/Docker/bash/git config files via `export_all_proxy_configs`.

## Validation

User input is checked before any provisioning by `validate_username`, `validate_fingerprint`, `validate_external_proxy_assignment`, and (in the QR module) `validate_vless_uri`. See [[proxy-chains]], [[security]].

`validate_username` enforces 3–32 characters, the charset `[a-zA-Z0-9_-]`, and a reserved-name blacklist (`root`, `admin`, `administrator`, `system`, `default`, `test`, case-insensitive). `validate_fingerprint` accepts only the Reality-supported TLS fingerprints (`chrome`, `firefox`, `safari`, `edge`, `360`, `qq`, `ios`, `android`, `random`, `randomized`). `validate_external_proxy_assignment` treats an empty id as valid (direct routing) and otherwise confirms the id exists in `config/external_proxy.json`. `validate_vless_uri` checks the `vless://` scheme and required params, demanding the Reality-only `flow`/`pbk`/`sid` only when `security=reality`. Note: `lib/validation.sh` is unrelated — a v5.33 no-op stub kept only for reverse-proxy call-site compatibility.
