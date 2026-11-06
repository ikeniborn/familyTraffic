#!/usr/bin/env bash
# Run real protocol and metric checks inside an isolated Docker network.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export FT_TRAFFIC_ROOT="$root"
export FT_TRAFFIC_IMAGE="${FT_TRAFFIC_IMAGE:-familytraffic:proxy-auth-username}"
export FT_TRAFFIC_NODE_IMAGE="${FT_TRAFFIC_NODE_IMAGE:-familytraffic-security-node:local}"
docker image inspect "$FT_TRAFFIC_IMAGE" >/dev/null
if ! docker image inspect "$FT_TRAFFIC_NODE_IMAGE" >/dev/null 2>&1; then
    docker build -f "$root/tests/security_lab/node.Dockerfile" -t "$FT_TRAFFIC_NODE_IMAGE" "$root"
fi
export FT_TRAFFIC_LAB
FT_TRAFFIC_LAB=$(mktemp -d)
export COMPOSE_PROJECT_NAME
COMPOSE_PROJECT_NAME="ft-traffic-$(date +%s)-$$"
export FT_TRAFFIC_ARTIFACTS="$root/tests/monitoring/artifacts/$COMPOSE_PROJECT_NAME"
mkdir -p "$FT_TRAFFIC_ARTIFACTS"
if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
else
    compose=(/usr/libexec/docker/cli-plugins/docker-compose)
fi
cleanup() {
    local status=$?
    "${compose[@]}" -f "$root/tests/monitoring/compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$FT_TRAFFIC_LAB"
    exit "$status"
}
trap cleanup EXIT
CGO_ENABLED=0 go -C "$root/monitoring/exporter" build -trimpath -o "$FT_TRAFFIC_LAB/exporter" ./cmd/familytraffic-exporter
python3 "$root/tests/monitoring/lab.py"
