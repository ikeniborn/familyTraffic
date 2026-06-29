# Docker

## Overview

The familyTraffic image is a 3-stage build (xray-src → mtg-src → final on `nginx:alpine`) bundling supervisor, certbot, xray and mtg. Build args pin mtg version/arch. supervisord is PID 1; the entrypoint does a first-run certbot then execs it; certbot-renew loops every 12 h. Bumping `VERSION` on `test` triggers a GitHub Actions push to GHCR.

## Multi-Stage Build

`docker/familytraffic/Dockerfile` builds in three stages to keep the final image small and avoid compiling at build time.

Stage 1 `xray-src` is just `FROM ${XRAY_IMAGE}` (default `teddysun/xray:24.11.30`) — used only to copy out `/usr/bin/xray`. Stage 2 `mtg-src` runs `FROM alpine:latest`, installs curl, and downloads the prebuilt mtg v2 static binary from the `9seconds/mtg` GitHub release, installing it to `/usr/bin/mtg`. Stage 3 `final` is `FROM ${NGINX_IMAGE}` (default `nginx:1.27-alpine`); it `apk add`s `supervisor`, `certbot`, `iproute2` (`ss` for the port-80 check) and `netcat-openbsd` (`nc` for healthcheck), copies the xray and mtg binaries from the earlier stages, copies `supervisord.conf`, `certbot-renew.sh` and `entrypoint.sh` into `/etc/familytraffic/`, sets `INSTALL_PATH=/opt/familytraffic`, declares the `ENTRYPOINT`, and adds a fallback `HEALTHCHECK` probing TCP 8443 and 443. certbot is installed via apk (not pip) to avoid a Python interpreter-path mismatch with the apk-provided Python. See [[architecture]], [[installation]].

## Build Args

Four ARGs are declared before the first `FROM` (required for FROM-referenced ARGs) and override base versions at build time.

`XRAY_IMAGE` (default `teddysun/xray:24.11.30`) and `NGINX_IMAGE` (default `nginx:1.27-alpine`) select the source/base images. `MTG_VERSION` (default `2.2.3`) and `MTG_ARCH` (default `amd64`) are consumed in the `mtg-src` stage to build the release download URL `mtg-${MTG_VERSION}-linux-${MTG_ARCH}.tar.gz`. Example: `docker build --build-arg MTG_VERSION=2.2.3 --build-arg MTG_ARCH=amd64 -f docker/familytraffic/Dockerfile .`. See [[mtproxy]].

## Supervisord Base Config

`supervisord.conf` (copied to `/etc/familytraffic/`) defines the PID-1 process manager and the three baked-in programs; ordering is by `priority` since supervisord INI has no `depends_on`.

`[supervisord]` runs `nodaemon=true` with its own logfile discarded to `/dev/null`. A `[unix_http_server]` socket at `/var/run/supervisor.sock` (chmod 0700) backs `supervisorctl`. The programs are `xray` (priority 1, `xray run -c /etc/xray/config.json`, `autorestart=true`), `nginx` (priority 2, `daemon off`, `autorestart=true`), and `certbot-cron` (priority 3, runs `certbot-renew.sh`, `autorestart=false`, `startretries=1` — non-critical). All program logs are wired to `/dev/fd/1` and `/dev/fd/2`. An `[include]` pulls optional programs from the host-mounted `/opt/familytraffic/config/supervisord.d/*.conf` — this is how `mtg.conf` enables MTProxy. The Dockerfile also symlinks `/etc/supervisord.conf` to this file so bare `supervisorctl status` works without `-c`. See [[architecture#Process Supervision]], [[services]], [[mtproxy]].

## Entrypoint

`entrypoint.sh` (`/etc/familytraffic/entrypoint.sh`, the image `ENTRYPOINT`) is a two-phase POSIX `sh` script run with `set -e`; it requires the `DOMAIN` and `ACME_EMAIL` env vars.

Phase 1 runs only on first start, when `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` is absent: it pre-flight checks that port 80 is free (via `ss`/`netstat`, erroring out if occupied) and then obtains a certificate with `certbot certonly --standalone --non-interactive --agree-tos -m "${ACME_EMAIL}" -d "${DOMAIN}" --preferred-challenges http`. If the cert already exists, this phase is skipped. Phase 2 always runs `exec /usr/bin/supervisord -c /etc/familytraffic/supervisord.conf`, replacing the shell so supervisord becomes PID 1. See [[certificates]], [[architecture#Process Supervision]].

## Certbot-Renew Script

`certbot-renew.sh` is the long-running `certbot-cron` supervisord program — an infinite renewal loop, distinct from the entrypoint's one-shot `--standalone` issuance.

Each iteration runs `certbot renew --webroot --webroot-path /var/www/html --quiet` (nginx serves the `/.well-known/acme-challenge` path, so renewal needs no downtime), then `sleep 43200` (12 hours). `certbot renew` exits 0 whether or not a cert was due, so a `--deploy-hook` fires only on an actual renewal: it sends `SIGHUP` to nginx via `supervisorctl ... signal SIGHUP nginx` for a graceful reload. Errors are caught and logged with the exit code rather than killing the loop. See [[certificates]], [[services]].

## CI/CD & Versioning

The image is built and published by GitHub Actions (`.github/workflows/build-and-push.yml`), and the `VERSION` file (semver) is the single source of truth that triggers it.

The workflow runs on push or PR to the `test` branch filtered to the `VERSION` path (plus manual `workflow_dispatch`) — any code/config change must be accompanied by a `VERSION` bump to build. Job `build-and-push` logs in to GHCR, reads `VERSION`, and uses Buildx + `build-push-action` (context `.`, file `docker/familytraffic/Dockerfile`, `linux/amd64`, gha cache) to push two tags: `:latest` and `:<version>` to `ghcr.io/<owner>/familytraffic`. Job `cleanup-registry` prunes old images keeping the 3 latest while protecting `latest` and semver tags; job `notify` always sends a Telegram build status message. The published image is consumed by `docker-compose.yml` as `${GHCR_IMAGE}:${FT_IMAGE_TAG}`. See [[installation]], [[services]].
