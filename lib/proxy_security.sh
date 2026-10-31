#!/usr/bin/env bash
# Resolve explicit mode before persisted settings. Never source settings.
resolve_proxy_notls() {
    local current="${1-}" saved_file="${2-}" line value saved=""
    case "$current" in
        true|false) printf '%s\n' "$current"; return 0 ;;
        '') ;;
        *) echo 'Invalid explicit PROXY_NOTLS_ENABLED value' >&2; return 1 ;;
    esac
    if [[ -e "$saved_file" ]]; then
        [[ -f "$saved_file" && -r "$saved_file" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                PROXY_NOTLS_ENABLED=*)
                    value="${line#PROXY_NOTLS_ENABLED=}"
                    case "$value" in
                        true|false) ;;
                        *) echo 'Invalid saved PROXY_NOTLS_ENABLED value' >&2; return 1 ;;
                    esac
                    if [[ -n "$saved" && "$saved" != "$value" ]]; then
                        echo 'Conflicting saved PROXY_NOTLS_ENABLED values' >&2
                        return 1
                    fi
                    saved="$value"
                    ;;
            esac
        done < "$saved_file"
    fi
    printf '%s\n' "${saved:-false}"
}
