#!/bin/sh
# Fetch only the reviewed upstream revision. Never build an unpatched fallback.
set -eu
revision=98a72b6fb49bcc403c4cae1ff529b9def43e6ad8
resources=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode=${1:-build}
case "$mode" in build|focused|all) ;; *) echo 'Expected build, focused, or all' >&2; exit 2 ;; esac
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT HUP INT TERM
git init -q "$workspace"
git -C "$workspace" remote add origin https://github.com/XTLS/Xray-core.git
git -C "$workspace" fetch -q --depth=1 origin "$revision"
git -C "$workspace" checkout -q --detach FETCH_HEAD
[ "$(git -C "$workspace" rev-parse HEAD)" = "$revision" ]
git -C "$workspace" apply --check "$resources/auth-journal.patch"
git -C "$workspace" apply "$resources/auth-journal.patch"
cd "$workspace"
case "$mode" in
    focused) go test -race ./common/ftauth ./proxy/http ./proxy/socks ;;
    all)
        # Upstream tests require the geodata normally restored from their CI cache.
        # Pin that test input to the same release and verify the archive bytes.
        curl -fsSL https://github.com/XTLS/Xray-core/releases/download/v24.11.30/Xray-linux-64.zip -o geodata.zip
        printf '%s\n' '679d6ec1c2ecabd84ad1e2deab6e52789c52f0a387902cc72e135a3bb3949554  geodata.zip' | sha256sum -c -
        mkdir resources
        unzip -j geodata.zip geoip.dat geosite.dat -d resources
        go test -timeout 5m ./...
        ;;
    build) CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags='-s -w' -o "${2:-/usr/bin/xray}" ./main ;;
esac
