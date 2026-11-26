#!/bin/sh
# docker/familytraffic/certbot-renew.sh
# Certificate renewal loop — runs as supervisord program:certbot-cron
# Checks every 12 hours; uses certbot --webroot for renewal (nginx serves /.well-known/)
# On actual renewal: sends SIGHUP to nginx (graceful reload, no downtime)

# Fresh installations register per-certificate hooks with the host Certbot timer.
[ -z "${FT_SERVICE_MODE:-}" ] || exit 0

while true; do
    # certbot renew exits 0 both when renewed and when not due yet.
    # --deploy-hook runs only when a certificate is actually renewed.
    certbot renew \
        --webroot \
        --webroot-path /var/www/html \
        --deploy-hook 'supervisorctl -c /etc/familytraffic/supervisord.conf signal SIGHUP nginx && echo "$(date): cert renewed, nginx reloaded"' \
        --quiet 2>&1 || echo "$(date): cert renewal error (exit $?)"

    sleep 43200  # 12 hours
done
