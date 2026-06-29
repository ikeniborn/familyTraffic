# MTProxy

## Overview

familyTraffic ships an optional Telegram MTProxy via mtg v2 on public port 2053 (Fake TLS) inside the familytraffic container. The `familytraffic-mtproxy` CLI runs the lifecycle by creating/removing a supervisord drop-in (`mtg.conf`), opening/closing UFW 2053, and regenerating nginx with cloak-port 4443. Secrets use the ee Fake-TLS format; runtime config lives in `mtg.toml`.

## Lifecycle & Supervisord Integration

`familytraffic-mtproxy` (root-only) drives the MTProxy lifecycle via `lib/mtproxy_manager.sh`. Setup runs five steps; disable reverses them. See [[cli-tools#familytraffic-mtproxy]] and [[architecture#Process Supervision]].

`cmd_setup` (optionally `--fake-domain <site>`; `--domain` is a deprecated alias) resolves the fake-TLS domain (from the flag or `_get_cert_domain`/`.env`), validates it with `validate_fake_tls_domain` (must have an A record, must be reachable on :443, and must not have AAAA when the server lacks global IPv6 — otherwise mtg tries IPv6 first, times out, and strict clients hang), then: (1) generates `mtg.toml`, (2) opens UFW 2053, (3) regenerates `nginx.conf` with cloak-port enabled and reloads nginx, (4) enables mtg, (5) prints the `tg://proxy?...` deep link. It also (re)generates a fresh ee-secret when `--fake-domain` is explicit or no ee-secret exists, deleting stale ee-secrets first.

Enable/disable map to two functions. `mtg_supervisord_enable` writes `${VLESS_HOME}/config/supervisord.d/mtg.conf` (`[program:mtg]`, `command=/usr/bin/mtg run /opt/familytraffic/config/mtproxy/mtg.toml`, `autostart=true`, `autorestart=true`), then runs `supervisorctl reread` + `update` + `restart mtg` so the running daemon both starts and reloads `mtg.toml` (reread/update alone won't reload an already-running process). `mtg_supervisord_disable_config` (called by `cmd_disable`) stops mtg, removes `mtg.conf`, then reread/update so the program is dropped; disable also closes UFW 2053 and regenerates nginx without the cloak-port. `start`/`stop`/`restart`/`status` call `supervisorctl ... mtg` directly via `docker exec`; `mtproxy_is_running` greps `RUNNING`.

## Secret Format

`lib/mtproxy_secret_manager.sh` makes three secret types: `standard` (32 hex), `dd` (`dd` + 32 hex), and `ee` (`ee` + 32 hex key + full-domain UTF-8 hex, Fake TLS). Port 2053 requires an ee-secret; secrets persist in `secrets.json`. See [[security]].

`generate_mtproxy_secret <type> [domain]` produces 16 random bytes via `openssl rand -hex 16` (falling back to `/dev/urandom` + `xxd`). For ee it appends `encode_domain_to_hex`, which hex-encodes the full hostname (UTF-8, no truncation) with `xxd -p` or `hexdump` — so an ee-secret's length varies with the fake-domain. The fake-domain is embedded in the secret and used by mtg to masquerade as that real HTTPS site; it need not be the server's own domain (e.g. `www.google.com`).

`validate_mtproxy_secret` matches by regex: `^dd[0-9a-fA-F]{32}$` (dd), `^ee[0-9a-fA-F]{34,}$` (ee — note the `{34,}` lower bound covering the 32-hex key plus at least one domain byte), or `^[0-9a-fA-F]{32}$` (standard). `add_secret_to_db` validates, rejects duplicates, and writes `{secret,type,username,domain,created_at}` into `secrets.json` under an `flock` lock with an atomic `.tmp`→`mv` and re-`chmod 600`. `remove_secret_from_db` deletes by secret or username the same way. The CLI exposes `add-secret`/`list-secrets`/`remove-secret`, which also regenerate the line-per-secret `proxy-secret` file and refresh `mtg.toml`/restart mtg when active.

## mtg.toml Structure

`generate_mtg_toml <masquerade_domain>` writes `mtg.toml` (mode 600, `.bak` first), reading the first ee-type secret from `secrets.json` and aborting if none is found. The masquerade domain defaults to `DOMAIN` from `.env` when not passed.

The emitted TOML sets `secret`, `bind-to = "0.0.0.0:2053"`, and three deliberately-placed keys: `prefer-ip = "prefer-ipv4"` at **top level** (NOT under `[network]`) to stop mtg defaulting to IPv6 on IPv4-only servers, and `tolerate-time-skewness = "3m"` to survive clock drift / blocked NTP. Under `[network]`, `dns = "udp://8.8.8.8"` uses plain UDP DNS instead of DoH (needs mtg ≥ 2.1.12); `[network.timeout]` sets `tcp = "5s"`. The `[cloak]` block sets `port = 4443` — invalid/probe connections are cloaked to the loopback nginx cloak-port that serves real TLS with the Let's Encrypt cert (see [[certificates]]), so probers see genuine HTTPS rather than a proxy fingerprint.

## Ports & Firewall

Port 2053/tcp carries the mtg Fake-TLS service to Telegram and is the only port opened in the firewall. Port 4443, the nginx cloak-port for active-probing protection, is loopback-only and must never be opened. See [[security]] and [[architecture]].

`mtg_ufw_allow` (called from setup) no-ops if `ufw` is absent or inactive or the rule already exists, otherwise runs `ufw allow 2053/tcp comment 'MTProxy Fake TLS (mtg v2)'` + `ufw reload`. `mtg_ufw_deny` (called from disable) symmetrically removes it. The cloak-port 4443 is wired only inside `nginx.conf` (regenerated with the cloak block on setup, without it on disable) and is reachable solely on loopback from mtg — setup explicitly warns "do NOT open in UFW". Clients connect with the Telegram deep link `tg://proxy?server=<ip>&port=2053&secret=<ee-secret>`, also rendered as a QR code via `generate_mtproxy_qrcode`. mtg v2 exposes no HTTP stats endpoint, so monitoring is via `familytraffic-mtproxy status` and `logs` (supervisord). See [[user-management]] for per-user secrets and [[services]] for process operations.
