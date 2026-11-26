#!/usr/bin/env bash
# Exercise the generated public listeners inside isolated container networks.
set -euo pipefail
image=${FT_TEST_IMAGE:?Set FT_TEST_IMAGE to a locally built application image}
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
node=""
cleanup() {
    if [[ -n $node ]]; then docker rm -f "$node" >/dev/null; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/certs/live/service.test" "$work/web/.well-known/acme-challenge"
echo 'service-mode-target' > "$work/web/.well-known/acme-challenge/check"
cert="$work/certs/live/service.test"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=service.test \
    -addext subjectAltName=DNS:service.test -out "$cert/fullchain.pem" -keyout "$cert/privkey.pem" 2>/dev/null
export XRAY_CONFIG="$work/xray.json" USERS_JSON="$work/users.json" GHCR_IMAGE=local/familytraffic
export FT_SERVICE_MODE FT_VLESS_PUBLIC_PORT FT_HTTPS_PROXY_PORT FT_SOCKS_TLS_PORT FT_HTTP_PLAIN_PORT FT_SOCKS_PLAIN_PORT
source "$root/lib/common.sh"
source "$root/lib/orchestrator.sh"

health() {
    local attempt
    for attempt in {1..60}; do
        if docker exec "$node" /etc/familytraffic/healthcheck.sh 2>/dev/null; then return 0; fi
        sleep .2
    done
    docker logs --tail 16 "$node" >&2
    return 1
}

probe_https() {
    docker exec "$node" curl --silent --show-error --max-time 4 --fail --noproxy '' \
        --proxy-cacert /etc/letsencrypt/live/service.test/fullchain.pem \
        --resolve "service.test:$FT_HTTPS_PROXY_PORT:127.0.0.1" --proxy "https://service.test:$FT_HTTPS_PROXY_PORT" \
        "$@" --proxytunnel http://127.0.0.1/.well-known/acme-challenge/check
}

private=$(docker run --rm --network none --entrypoint xray "$image" x25519 | awk '/Private key:/ {print $3}')
for selection in 'vpn 443 - - - -' 'vpn 9440 - - - -' 'proxy - 443 - - -' 'proxy - 9440 9100 9119 9101' 'both 443 8118 - - -' 'both 9440 9441 9100 - -'; do
    read -r FT_SERVICE_MODE vpn https socks plain_http plain_socks <<< "$selection"
    FT_VLESS_PUBLIC_PORT=${vpn#-} FT_HTTPS_PROXY_PORT=${https#-} FT_SOCKS_TLS_PORT=${socks#-}
    FT_HTTP_PLAIN_PORT=${plain_http#-} FT_SOCKS_PLAIN_PORT=${plain_socks#-}
    DOMAIN='' PROXY_NOTLS_ENABLED=false enable_proxy=false
    if [[ -n $FT_HTTP_PLAIN_PORT ]]; then PROXY_NOTLS_ENABLED=true; fi
    PRIVATE_KEY='' REALITY_DEST='' REALITY_DEST_PORT='' VLESS_PORT='' SHORT_ID=''
    if [[ -n $FT_VLESS_PUBLIC_PORT ]]; then
        PRIVATE_KEY=$private REALITY_DEST=127.0.0.1 REALITY_DEST_PORT=9448 VLESS_PORT=8443 SHORT_ID=0123456789abcdef
    fi
    if [[ -n $FT_HTTPS_PROXY_PORT ]]; then DOMAIN=service.test enable_proxy=true; fi
    printf '{"users":[]}\n' > "$USERS_JSON"
    create_xray_config "$enable_proxy" >/dev/null
    generate_nginx_config "$DOMAIN" false '' '' '' false "$PROXY_NOTLS_ENABLED" > "$work/nginx.conf"
    node=$(docker run -d --network none --pull never -e FT_SERVICE_MODE -e FT_VLESS_PUBLIC_PORT -e FT_HTTPS_PROXY_PORT \
        -e FT_SOCKS_TLS_PORT -e FT_HTTP_PLAIN_PORT -e FT_SOCKS_PLAIN_PORT -e DOMAIN="$DOMAIN" -e ACME_EMAIL=lab@example.test \
        -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$XRAY_CONFIG:/etc/xray/config.json:ro" \
        -v "$work/certs:/etc/letsencrypt:ro" -v "$work/web:/var/www/html:ro" "$image")
    health
    if [[ $enable_proxy == true ]]; then
        if probe_https >/dev/null 2>&1; then echo 'Anonymous request reached target' >&2; exit 1; fi
        printf '{"users":[{"username":"alice","connection_type":"proxy","proxy_password":"fixture-password"}]}' > "$USERS_JSON"
        (source "$root/lib/user_management.sh"; update_proxy_accounts alice fixture-password)
    fi
    docker restart "$node" >/dev/null
    health
    if [[ $enable_proxy == true ]]; then
        [[ $(probe_https --proxy-user alice:fixture-password) == service-mode-target ]]
    fi
    docker exec "$node" supervisorctl stop xray >/dev/null
    if docker exec "$node" /etc/familytraffic/healthcheck.sh; then echo "Missing backend passed health" >&2; exit 1; fi
    # A different process can take the released socket before the next check.
    backend=18118
    [[ -z $FT_VLESS_PUBLIC_PORT ]] || backend=8443
    docker exec -d "$node" nc -lk 127.0.0.1 "$backend"
    for _ in {1..20}; do docker exec "$node" nc -z 127.0.0.1 "$backend" && break; sleep .1; done
    if docker exec "$node" /etc/familytraffic/healthcheck.sh; then echo "Wrong process passed health" >&2; exit 1; fi
    docker exec "$node" pkill -x nc
    docker exec "$node" supervisorctl start xray >/dev/null
    health
    docker rm -f "$node" >/dev/null
    node=""
    echo "Passed: $selection"
done
