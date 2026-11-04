#!/bin/bash
# Run patched upstream tests in the same immutable builder used by the image.
set -euo pipefail
mode=${1:-focused}
case "$mode" in focused|all) ;; *) echo 'Expected focused or all' >&2; exit 2 ;; esac
resources=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder=golang:1.23.4-alpine@sha256:c23339199a08b0e12032856908589a6d41a0dab141b8b3b21f156fc571a3f1d3
docker run --rm -v "$resources:/resources:ro" "$builder" sh -ec 'apk add --no-cache git gcc musl-dev curl unzip; sh /resources/build.sh "$1"' sh "$mode"
