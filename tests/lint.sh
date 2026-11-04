#!/bin/bash
# tests/lint.sh — ShellCheck gate for CI and local runs.
#
# Two rules:
#   1. Any finding of severity `error` fails immediately. There are none today,
#      so this stays a hard gate.
#   2. The total finding count may never exceed the recorded baseline. Fixing
#      findings is encouraged; the baseline is lowered by running this script
#      with --update-baseline.
#
# Configuration (which checks are disabled and why) lives in .shellcheckrc.
#
# Usage:
#   tests/lint.sh                    # check against the baseline
#   tests/lint.sh --update-baseline  # record the current count after fixing findings

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/tests/shellcheck-baseline.txt"

cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not found. Install it with: sudo apt-get install -y shellcheck" >&2
    exit 127
fi

# Tracked shell sources. scripts/* is listed without a glob suffix because the
# CLI entry points carry a shebang but no .sh extension.
mapfile -t TARGETS < <(git ls-files 'lib/*.sh' 'lib/tests/*.sh' 'scripts/*' 'install.sh' 'docker/familytraffic/*.sh')

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "No shell sources found — refusing to report a vacuous pass." >&2
    exit 1
fi

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

# shellcheck exits non-zero when it reports anything; the counts below are the
# actual gate, so its exit status is deliberately ignored here.
shellcheck -f gcc "${TARGETS[@]}" > "$REPORT" 2>/dev/null || true

errors=$(grep -c ': error:' "$REPORT" || true)
total=$(wc -l < "$REPORT")

echo "shellcheck: ${#TARGETS[@]} files, ${total} findings (${errors} errors)"

if [[ "${1:-}" == "--update-baseline" ]]; then
    echo "$total" > "$BASELINE_FILE"
    echo "Baseline updated to ${total}."
    exit 0
fi

if [[ "$errors" -gt 0 ]]; then
    echo ""
    echo "FAIL: ${errors} error-severity finding(s):"
    grep ': error:' "$REPORT"
    exit 1
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "No baseline at ${BASELINE_FILE}. Create one with: tests/lint.sh --update-baseline" >&2
    exit 1
fi

baseline=$(<"$BASELINE_FILE")

if [[ "$total" -gt "$baseline" ]]; then
    echo ""
    echo "FAIL: findings rose from ${baseline} to ${total}."
    echo "Fix the new findings, or justify them in .shellcheckrc."
    exit 1
fi

if [[ "$total" -lt "$baseline" ]]; then
    echo ""
    echo "Findings dropped from ${baseline} to ${total}. Lower the baseline:"
    echo "  tests/lint.sh --update-baseline"
    exit 1
fi

echo "OK: at baseline (${baseline})."
