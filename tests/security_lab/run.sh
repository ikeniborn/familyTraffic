#!/usr/bin/env bash
# Confine rules to disposable resources. Never mount the host Docker socket.
set -euo pipefail
[[ "${1:-}" == --image && $# == 2 ]] || { echo 'Usage: run.sh --image LOCAL_IMAGE' >&2; exit 2; }
export FT_LAB_IMAGE FT_LAB_SUBNET
FT_LAB_IMAGE=$(docker image inspect --format '{{.Id}}' "$2")
export FT_LAB_REPO FT_LAB_DIR FT_LAB_NODE_IMAGE COMPOSE_PROJECT_NAME FT_LAB_ARTIFACT_DIR
FT_LAB_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FT_LAB_DIR=$(mktemp -d)
FT_LAB_SUBNET=$(python3 "$FT_LAB_REPO/tests/security_lab/select_subnet.py")
COMPOSE_PROJECT_NAME="ft-security-$(date +%s)-$$"
FT_LAB_NODE_IMAGE="$COMPOSE_PROJECT_NAME-node"
FT_LAB_ARTIFACT_DIR="$FT_LAB_REPO/tests/security_lab/artifacts/$COMPOSE_PROJECT_NAME"
mkdir -p "$FT_LAB_ARTIFACT_DIR"
printf '%s\n' "$FT_LAB_IMAGE" > "$FT_LAB_ARTIFACT_DIR/image-id.txt"
sha256sum "$FT_LAB_REPO"/lib/{proxy_security,fail2ban_setup,nginx_stream_generator,orchestrator,user_management,verification}.sh "$FT_LAB_REPO"/scripts/{familytraffic-security,familytraffic} "$FT_LAB_REPO"/install.sh "$FT_LAB_REPO"/tests/unit/test_proxy_security_migration.bats "$FT_LAB_REPO"/tests/security_lab/{compose.yml,node.Dockerfile,probe.py,test_proxy_security.py,select_subnet.py,run.sh} > "$FT_LAB_ARTIFACT_DIR/source-sha256.txt"
if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
else
    export FT_LAB_COMPOSE=/usr/libexec/docker/cli-plugins/docker-compose
    compose=("$FT_LAB_COMPOSE")
fi
compose+=(-f "$FT_LAB_REPO/tests/security_lab/compose.yml")
cleanup() {
    local result=$?
    "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    docker image rm "$FT_LAB_NODE_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$FT_LAB_DIR"
    exit "$result"
}
trap cleanup EXIT
# Build only the disposable test node; require an existing application image.
if docker buildx version >/dev/null 2>&1; then
    builder=(docker buildx build --load)
else
    builder=(/usr/libexec/docker/cli-plugins/docker-buildx build --load)
fi
"${builder[@]}" --build-arg HTTP_PROXY= --build-arg HTTPS_PROXY= -f "$FT_LAB_REPO/tests/security_lab/node.Dockerfile" -t "$FT_LAB_NODE_IMAGE" "$FT_LAB_REPO"
python3 "$FT_LAB_REPO/tests/security_lab/test_proxy_security.py" 2>&1 | tee "$FT_LAB_ARTIFACT_DIR/results.log"

# Synthetic deployment faults are reported separately from real network acceptance.
bats "$FT_LAB_REPO/tests/unit/test_proxy_security_migration.bats" 2>&1 | tee "$FT_LAB_ARTIFACT_DIR/migration-results.log"
