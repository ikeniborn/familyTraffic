#!/usr/bin/env bash
# Public service ports are independent of Xray's internal receiver ports.

SERVICE_SETTINGS_READER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/service_settings.py"

validate_service_settings() {
    local mode=${FT_SERVICE_MODE-} vpn=${FT_VLESS_PUBLIC_PORT-}
    local https=${FT_HTTPS_PROXY_PORT-} socks=${FT_SOCKS_TLS_PORT-}
    local http=${FT_HTTP_PLAIN_PORT-} plain_socks=${FT_SOCKS_PLAIN_PORT-}
    local -A used=()
    local port
    for port in "$vpn" "$https" "$socks" "$http" "$plain_socks"; do
        [[ -n $port ]] || continue
        if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
            echo "Invalid public TCP port: $port" >&2
            return 1
        fi
        if [[ -n ${used[$port]-} ]]; then
            echo "Duplicate public TCP port: $port" >&2
            return 1
        fi
        used[$port]=1
    done
    case "$mode" in
        vpn) [[ -n $vpn && -z $https$socks$http$plain_socks ]] && return 0 ;;
        proxy|both)
            if [[ $mode == proxy && -n $vpn || $mode == both && -z $vpn ]]; then
                :
            elif [[ -n $https && ( -z $plain_socks || -n $socks ) ]]; then
                return 0
            elif [[ ${FT_LEGACY_SERVICE_SETTINGS:-false} == true && -z $https$socks && -n $http ]]; then
                return 0
            fi ;;
    esac
    echo "Inconsistent public ports for FT_SERVICE_MODE=$mode" >&2
    return 1
}

load_service_settings() {
    local root=$1 settings key value
    settings=$(python3 "$SERVICE_SETTINGS_READER" "$root") || return 1
    while IFS='=' read -r key value; do
        export "$key=$value"
    done <<< "$settings"
    validate_service_settings
}
