#!/bin/sh
set -eu

case "${FT_SERVICE_MODE-legacy}" in
    legacy)
        ports=$(python3 /etc/familytraffic/service_settings.py --legacy-health /etc/xray/config.json /etc/nginx/nginx.conf) || exit 1
        # The resolver emits decimal port numbers, one per line.
        set -- $ports ;;
    vpn) set -- "${FT_VLESS_PUBLIC_PORT:?}" "${VLESS_PORT:-8443}" ;;
    proxy) set -- "${FT_HTTPS_PROXY_PORT:?}" 18118 ;;
    both) set -- "${FT_VLESS_PUBLIC_PORT:?}" "${VLESS_PORT:-8443}" "${FT_HTTPS_PROXY_PORT:?}" 18118 ;;
    *) exit 1 ;;
esac
if [ -n "${FT_SOCKS_TLS_PORT:-}" ]; then
    set -- "$@" "$FT_SOCKS_TLS_PORT" 10800
fi
listeners=$(ss -H -ltnp) || exit 1
for port in "$@" ${FT_HTTP_PLAIN_PORT:+"$FT_HTTP_PLAIN_PORT"} ${FT_SOCKS_PLAIN_PORT:+"$FT_SOCKS_PLAIN_PORT"}; do
    case "$port" in
        "${VLESS_PORT:-8443}"|18118|10800) process=xray ;;
        *) process=nginx ;;
    esac
    printf '%s\n' "$listeners" | awk -v port="$port" -v process="$process" '
        $4 ~ (":" port "$") && index($0, "\"" process "\"") {found=1}
        END {exit !found}' || exit 1
    nc -z -w 3 127.0.0.1 "$port" || exit 1
done
