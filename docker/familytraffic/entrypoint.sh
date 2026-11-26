#!/bin/sh
# docker/familytraffic/entrypoint.sh
# familyTraffic container entrypoint — two-phase startup:
#   Phase 1: certbot --standalone (first run only, port 80 must be free)
#   Phase 2: exec supervisord (nginx + xray + certbot-cron)

set -e

if [ "${FT_SERVICE_MODE:-}" = vpn ] && [ -z "${DOMAIN:-}" ]; then
    exec /usr/bin/supervisord -c /etc/familytraffic/supervisord.conf
fi

DOMAIN="${DOMAIN:?DOMAIN env var required}"
ACME_EMAIL="${ACME_EMAIL:?ACME_EMAIL env var required}"

# Phase 1: Obtain TLS certificate on first run
if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "[entrypoint] First run: obtaining TLS certificate for ${DOMAIN}..."

    # Pre-flight: verify port 80 is free (required for certbot --standalone)
    if ss -tlnp 2>/dev/null | grep -q ':80 ' || netstat -tlnp 2>/dev/null | grep -q ':80 '; then
        echo "[entrypoint] ERROR: Port 80 is occupied, cannot run certbot --standalone" >&2
        echo "[entrypoint] Free port 80 before starting the container" >&2
        exit 1
    fi

    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        -m "${ACME_EMAIL}" \
        -d "${DOMAIN}" \
        --preferred-challenges http

    echo "[entrypoint] TLS certificate obtained successfully"
else
    echo "[entrypoint] TLS certificate already present for ${DOMAIN}"
fi

# Phase 2: Start all services via supervisord
echo "[entrypoint] Starting supervisord (nginx + xray + certbot-cron)..."
exec /usr/bin/supervisord -c /etc/familytraffic/supervisord.conf
