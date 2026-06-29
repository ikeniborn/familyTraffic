# docker/familytraffic/Dockerfile
# familyTraffic VPN Server - Single Container Image
# nginx + xray + certbot + supervisord
#
# 3-stage build:
#   Stage 1: xray-src — extract xray binary from teddysun image
#   Stage 2: mtg-src  — download mtg v2 static binary (nineseconds/mtg)
#   Stage 3: final    — nginx:alpine + supervisor + certbot (apk) + xray + mtg
#
# Override base image versions at build time:
#   docker build --build-arg NGINX_IMAGE=nginx:1.27-alpine .
#
# NOTE: certbot is installed via apk (not pip) to avoid Python interpreter
# path mismatch. pip-installed certbot embeds #!/usr/local/bin/python3.12
# which does not exist when supervisor brings Python via Alpine apk (/usr/bin).

# All FROM-referenced ARGs must be declared before the first FROM.
ARG XRAY_IMAGE=teddysun/xray:24.11.30
ARG NGINX_IMAGE=nginx:1.27-alpine
ARG MTG_VERSION=2.2.3
ARG MTG_ARCH=amd64

# =============================================================================
# Stage 1: Extract Xray binary
# =============================================================================
FROM ${XRAY_IMAGE} AS xray-src

# =============================================================================
# Stage 2: Download mtg static binary (no compilation)
# =============================================================================
FROM alpine:latest AS mtg-src
ARG MTG_VERSION
ARG MTG_ARCH
RUN apk add --no-cache curl && \
    curl -fL \
    "https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-${MTG_ARCH}.tar.gz" \
    | tar -xz --strip-components=1 -C /tmp && \
    install -m 755 /tmp/mtg /usr/bin/mtg

# =============================================================================
# Stage 3: Final image
# =============================================================================
FROM ${NGINX_IMAGE} AS final

# Runtime packages:
#   supervisor     — process manager (PID 1); brings python3 as apk dep
#   certbot        — ACME client for Let's Encrypt (Alpine community repo)
#   iproute2       — provides 'ss' for port-80 pre-flight check (entrypoint.sh)
#   netcat-openbsd — provides 'nc -w' for Docker healthcheck
RUN apk add --no-cache \
    supervisor \
    certbot \
    iproute2 \
    netcat-openbsd \
    && mkdir -p /etc/familytraffic \
    && mkdir -p /var/log/xray \
    && mkdir -p /var/www/html/.well-known/acme-challenge

# Copy xray binary from Stage 1
COPY --from=xray-src /usr/bin/xray /usr/bin/xray

# Copy mtg binary from Stage 2
COPY --from=mtg-src /usr/bin/mtg /usr/bin/mtg

# Config file (644 — no --chmod needed)
COPY docker/familytraffic/supervisord.conf /etc/familytraffic/supervisord.conf

# Bare `supervisorctl` defaults to /etc/supervisord.conf (which apt/apk ships pointing at
# the wrong socket). Symlink it to the real config so `supervisorctl status` works without -c.
RUN ln -sf /etc/familytraffic/supervisord.conf /etc/supervisord.conf

# Runtime scripts — merged into one COPY to save a layer
COPY --chmod=755 \
    docker/familytraffic/certbot-renew.sh \
    docker/familytraffic/entrypoint.sh \
    /etc/familytraffic/

ENV INSTALL_PATH=/opt/familytraffic

# Documentation only — actual binding controlled by network_mode:host in compose
EXPOSE 443 1080 1081 8118 8119 2053

# Fallback healthcheck — overridden by docker-compose.yml when run via compose
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=20s \
    CMD nc -z -w 3 127.0.0.1 8443 && nc -z -w 3 127.0.0.1 443

ENTRYPOINT ["/etc/familytraffic/entrypoint.sh"]
