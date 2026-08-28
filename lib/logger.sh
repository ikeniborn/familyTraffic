#!/bin/bash
# ============================================================================
# lib/logger.sh
# The one logging module. Every script and library sources this rather than
# declaring its own log_* functions.
#
# Usage:
#   source lib/logger.sh
#   log_info "Starting"
#   log_error "Could not read config"
#
# Output shape:
#   terminal      [INFO] Starting
#   pipe or file  2026-08-28 20:31:07 [INFO] Starting
#
# The timestamp appears only when the stream is not a terminal, and colour only
# when it is. Interactive output stays as terse as it has always been, while
# anything captured — a log file, a pipe, CI — carries the time it happened.
#
# Configuration, all optional:
#   LOG_COMPONENT   tag inserted before the level, e.g. LOG_COMPONENT=mtproxy
#                   renders "[mtproxy] [INFO] ...". Unset for no tag.
#   LOG_FILE        path; every line is appended there in full form
#                   (timestamp always present) in addition to the stream.
#   LOG_LEVEL       0=DEBUG 1=INFO 2=WARNING 3=ERROR 4=CRITICAL. Messages below
#                   the level are dropped. Defaults to 1.
#   DEBUG=true      shorthand for LOG_LEVEL=0.
#
# Every function returns 0 so a log call can never abort a caller running
# under `set -e`. Warnings, errors and criticals go to stderr; the rest to
# stdout.
# ============================================================================

# Guard against double sourcing.
if [[ -n "${FAMILYTRAFFIC_LOGGER_LOADED:-}" ]]; then
    return 0
fi
FAMILYTRAFFIC_LOGGER_LOADED=1

# Numeric severities, exported for callers that filter by level.
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARNING=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_CRITICAL=4

LOG_LEVEL="${LOG_LEVEL:-1}"

# ----------------------------------------------------------------------------
# Internal: emit one line.
# Arguments: $1 label, $2 severity number, $3 colour code, $4 stream (1|2), $@ message
# ----------------------------------------------------------------------------
_log_emit() {
    local label="$1"
    local severity="$2"
    local colour="$3"
    local stream="$4"
    shift 4

    # Read the threshold at call time, not at load time: DEBUG is routinely
    # exported after the module has been sourced.
    local threshold="${LOG_LEVEL:-1}"
    [[ "${DEBUG:-}" == "true" ]] && threshold=0

    [[ "$severity" -lt "$threshold" ]] && return 0

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local component=""
    [[ -n "${LOG_COMPONENT:-}" ]] && component="[${LOG_COMPONENT}] "

    # A terminal gets colour and no timestamp; anything captured gets the
    # timestamp and no escape codes.
    local line
    if [[ -t "$stream" ]]; then
        line="${component}\033[${colour}m[${label}]\033[0m $*"
    else
        line="${timestamp} ${component}[${label}] $*"
    fi

    if [[ "$stream" == "2" ]]; then
        printf '%b\n' "$line" >&2
    else
        printf '%b\n' "$line"
    fi

    # The log file always gets the full form, whatever the stream looked like.
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s %s[%s] %s\n' "$timestamp" "$component" "$label" "$*" >> "$LOG_FILE" 2>/dev/null || true
    fi

    return 0
}

log_debug() {
    _log_emit "DEBUG" "$LOG_LEVEL_DEBUG" "0;36" 1 "$@"
}

log_info() {
    _log_emit "INFO" "$LOG_LEVEL_INFO" "0;34" 1 "$@"
}

log_success() {
    _log_emit "SUCCESS" "$LOG_LEVEL_INFO" "0;32" 1 "$@"
}

log_warn() {
    _log_emit "WARN" "$LOG_LEVEL_WARNING" "1;33" 2 "$@"
}

# Alias: most of the repository calls log_warning.
log_warning() {
    log_warn "$@"
}

log_error() {
    _log_emit "ERROR" "$LOG_LEVEL_ERROR" "0;31" 2 "$@"
}

log_critical() {
    _log_emit "CRITICAL" "$LOG_LEVEL_CRITICAL" "1;31" 2 "$@"
}
