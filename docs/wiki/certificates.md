# Certificates

## Overview

familyTraffic uses Let's Encrypt certificates (certbot, ACME HTTP-01) for its TLS-terminating proxies. Acquisition validates DNS, opens port 80, runs a temporary nginx, and stores certs under `/etc/letsencrypt/live/<domain>/`. An in-container 12h loop auto-renews and SIGHUPs nginx; a host monitor and deploy hook add reporting. See [[architecture#Process Supervision]], [[transports]].

## Certbot Setup

`lib/certbot_setup.sh` installs and drives the Let's Encrypt client, then exposes `obtain_certificate(domain, email)` as the public acquisition entry point.

`install_certbot()` checks for the `certbot` binary and `apt install`s it if missing; `validate_domain_dns()` uses `dig +short` to confirm the domain's A record matches the server IP before any request. When `certificate_manager.sh` is loaded, `obtain_certificate` delegates to the unified `acquire_certificate_for_domain` workflow; otherwise it falls back to a legacy `certbot certonly --standalone` mode (clearing a stale `/var/lib/letsencrypt/.certbot.lock` first), then sets `600` on `privkey.pem`/`cert.pem` and `644` on `fullchain.pem`/`chain.pem`. `cleanup_certificates([domain])` removes the renewal cron plus a domain's `live/`, `renewal/`, and `archive/` data when switching to plaintext or uninstalling. See [[installation]], [[security]].

## Certificate Management

`lib/certificate_manager.sh` (v5.33) provides the unified acquisition workflow `acquire_certificate_for_domain(domain, email)` that wraps DNS validation and certbot.

It runs `validate_dns_for_domain()` first — auto-detecting the public IP from `api.ipify.org`/`ifconfig.me` and querying `dig @${DETECTED_DNS_PRIMARY:-8.8.8.8}` — then sources `letsencrypt_integration.sh` and calls `acquire_certificate` to run certbot. Since v5.33 removed HAProxy, the `create_haproxy_combined_cert`, `validate_haproxy_cert`, `create_combined_cert_for_all_domains`, and `reload_haproxy_after_cert_update` functions are kept only as no-op stubs: nginx inside the `familytraffic` container reads the Let's Encrypt PEMs directly, so no `combined.pem` is built. The module also exposes a small CLI (`validate-dns`, `acquire`, ...) for standalone testing. See [[architecture]].

## Let's Encrypt Integration

`lib/letsencrypt_integration.sh` is the certbot wrapper that actually issues and inspects certificates via the ACME HTTP-01 challenge.

`acquire_certificate(domain, email)` ensures the webroot `/var/www/certbot`, temporarily opens UFW port 80 (`open_port_80_for_certbot`, tracked by `PORT_80_OPENED_BY_US`), frees port 80 if occupied, starts a throwaway `certbot_nginx` (`nginx:alpine`, host network) serving the webroot, then runs `certbot certonly --webroot`. It explicitly stops the temp nginx and closes port 80 on return — not only via the EXIT trap — so the temp container cannot block the real nginx from binding 80. Without an email it uses `--register-unsafely-without-email`. Inspection helpers include `validate_certificate()`, `get_certificate_expiry()` (ISO-8601 via `openssl x509 -enddate`), `check_certificate_expiry_days()`, and `renew_certificate(domain)` (`certbot renew --cert-name <domain> --force-renewal --quiet`). See [[security]].

## Auto-Renewal (cron)

Two renewal mechanisms exist; the primary one runs inside the container as the supervisord `program:certbot-cron` (priority 3, `autorestart=false`).

`docker/familytraffic/certbot-renew.sh` loops forever, every `sleep 43200` (12 hours) running `certbot renew --webroot --webroot-path /var/www/html --deploy-hook '...'`. `certbot renew` exits 0 whether or not a cert was due, so the deploy hook — `supervisorctl signal SIGHUP nginx` — fires only on an actual renewal, giving a zero-downtime graceful reload. Separately, `setup_renewal_cron()` in `certbot_setup.sh` can install a host `/etc/cron.d/certbot-familytraffic-renew` running `certbot renew` at 00:00 and 12:00 UTC, whose deploy hook `docker exec`s the same SIGHUP into the container, logging to `/opt/familytraffic/logs/certbot-renew.log`. The richer deploy hook `familytraffic-cert-renew` adds retry/backoff, validation, rollback, and metrics. See [[architecture#Process Supervision]], [[cli-tools#familytraffic-cert-renew]].

## Renewal Monitoring

`lib/cert_renewal_monitor.sh` is a host-side monitor for reverse-proxy certificates tracked in the database, distinct from the in-container renewal loop.

It reads each proxy's `certificate_expires` field (`get_proxy`/`list_proxies`) and classifies status by thresholds: `AUTO_RENEW_THRESHOLD=30`, `WARNING_THRESHOLD=14`, `CRITICAL_THRESHOLD=7` days. Commands: `--check` (report only), `--auto-renew` (renew anything under 30 days via `renew_certificate`), `--report` (status table to `/tmp` and log), and `--setup-cron` (installs daily `0 2 * * *` auto-renew and weekly `0 9 * * 1` report jobs). Optional email alerts (`EMAIL_ALERTS=true`, `EMAIL_TO`) notify on renewals, failures, and critical/expired certs via the `mail` command. It must run as root and logs to `/var/log/vless/cert_renewal_monitor.log`. See [[proxy-chains]], [[cli-tools]].
