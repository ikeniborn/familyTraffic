#!/bin/bash
# ============================================================================
# lib/logger.sh
# Structured logging for familyTraffic scripts and tests.
#
# Usage:
#   source lib/logger.sh
#   log_info "Starting"
#   DEBUG=true log_debug "Only shown when DEBUG=true"
#
# Every function writes one timestamped line and always returns 0, so a log
# call can never abort a caller running under `set -e`. Errors and warnings go
# to stderr, everything else to stdout.
#
# Colors are emitted only when the stream is a terminal, keeping captured
# output (tests, pipes, log files) plain.
# ============================================================================

# Guard against double sourcing.
if [[ -n "${FAMILYTRAFFIC_LOGGER_LOADED:-}" ]]; then
    return 0
fi
FAMILYTRAFFIC_LOGGER_LOADED=1

# ----------------------------------------------------------------------------
# Internal: emit one "<timestamp> [LEVEL] <message>" line.
# Arguments: $1 level, $2 color code, $3 stream (1 or 2), $@ message
# ----------------------------------------------------------------------------
_log_emit() {
    local level="$1"
    local color="$2"
    local stream="$3"
    shift 3

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local prefix="${timestamp} [${level}]"

    # Colorize only when the target stream is a terminal.
    if [[ -t "$stream" ]]; then
        prefix="${timestamp} \033[${color}m[${level}]\033[0m"
    fi

    if [[ "$stream" == "2" ]]; then
        printf '%b %s\n' "$prefix" "$*" >&2
    else
        printf '%b %s\n' "$prefix" "$*"
    fi

    return 0
}

log_info() {
    _log_emit "INFO" "0;34" 1 "$@"
}

log_success() {
    _log_emit "SUCCESS" "0;32" 1 "$@"
}

log_warn() {
    _log_emit "WARN" "1;33" 2 "$@"
}

# Alias: most modules in this repository call log_warning.
log_warning() {
    log_warn "$@"
}

log_error() {
    _log_emit "ERROR" "0;31" 2 "$@"
}

# Silent unless DEBUG=true.
log_debug() {
    if [[ "${DEBUG:-}" != "true" ]]; then
        return 0
    fi
    _log_emit "DEBUG" "0;36" 1 "$@"
}
