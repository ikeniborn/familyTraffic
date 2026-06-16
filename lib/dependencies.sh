#!/bin/bash
#
# Dependency Auto-Installation Module
# Part of familyTraffic VPN Deployment System
#
# Purpose: Check and auto-install all required dependencies with extended Docker diagnostics
# Supports: Ubuntu 20.04+, Debian 10+
# Usage: source this file from install.sh (after os_detection.sh)
#
# Dependencies from os_detection.sh:
#   - OS_NAME: Operating system name
#   - OS_VERSION: OS version number
#   - OS_ID: OS identifier (ubuntu/debian)
#   - PKG_MANAGER: Package manager (apt/apt-get)
#
# Exit codes:
#   0 = success
#   1 = general error
#   3 = dependency error
#

# Only set strict mode if not already set (to avoid issues when sourced)
[[ ! -o pipefail ]] && set -euo pipefail || true

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Required packages for familyTraffic VPN system
REQUIRED_PACKAGES=(
    "docker.io"
    "docker-compose-plugin"
    "ufw"
    "jq"
    "qrencode"
    "curl"
    "openssl"
    "fail2ban"        # v3.3: Brute-force protection (all proxy modes)
    "logrotate"       # Rotate xray access/error logs (setup_xray_logrotate writes the config)
    "certbot"         # v3.3: Let's Encrypt client for TLS certificates
    "dnsutils"        # v3.3: DNS tools (dig) for certificate validation
    "tcpdump"         # v3.3: Packet capture for security testing
    "nmap"            # v3.3: Network scanner for security testing
)

# Optional packages (non-critical, system works without them)
# v3.3: netcat for Docker healthchecks (has fallbacks)
# v3.3: tshark for advanced security testing (Wireshark CLI)
OPTIONAL_PACKAGES=(
    "netcat-openbsd"  # For Docker healthchecks (fallback: netcat-traditional, ncat)
    "tshark"          # For advanced packet analysis in security tests (optional)
)

# Ensure it's properly declared as array for export
declare -ga REQUIRED_PACKAGES
declare -ga OPTIONAL_PACKAGES

# Minimum version requirements
readonly DOCKER_MIN_VERSION="20.10"
readonly DOCKER_COMPOSE_MIN_VERSION="1.29"
readonly JQ_MIN_VERSION="1.5"

# Color codes (inherited from os_detection.sh but redefined for standalone use if needed)
# Only define if not already set (to avoid conflicts when sourced after os_detection.sh)
# Note: Using non-readonly to avoid conflicts with os_detection.sh readonly declarations
[[ -z "${RED:-}" ]] && RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && BLUE='\033[0;34m'
[[ -z "${NC:-}" ]] && NC='\033[0m' # No Color
[[ -z "${CYAN:-}" ]] && CYAN='\033[0;36m'

# Progress symbols (non-readonly to avoid conflicts)
CHECK_MARK='\u2713'  # ✓
CROSS_MARK='\u2717'  # ✗
WARNING_MARK='\u26A0' # ⚠

# =============================================================================
# HELPER FUNCTION: version_compare
# =============================================================================
# Description: Compare two version strings (semantic versioning)
# Parameters:
#   $1: version1
#   $2: version2
# Returns: 0 if version1 >= version2, 1 otherwise
# Example: version_compare "20.10.5" "20.10" returns 0
# =============================================================================
version_compare() {
    local version1="$1"
    local version2="$2"

    # Remove leading 'v' if present
    version1="${version1#v}"
    version2="${version2#v}"

    # Split versions into arrays
    IFS='.' read -ra v1_parts <<< "$version1"
    IFS='.' read -ra v2_parts <<< "$version2"

    # Compare each part
    local max_parts=${#v1_parts[@]}
    [[ ${#v2_parts[@]} -gt $max_parts ]] && max_parts=${#v2_parts[@]}

    for ((i=0; i<max_parts; i++)); do
        local part1=${v1_parts[i]:-0}
        local part2=${v2_parts[i]:-0}

        # Remove non-numeric suffixes (e.g., "20.10.5-ce" -> "20.10.5")
        part1=$(echo "$part1" | grep -oE '^[0-9]+')
        part2=$(echo "$part2" | grep -oE '^[0-9]+')

        if [[ $part1 -gt $part2 ]]; then
            return 0
        elif [[ $part1 -lt $part2 ]]; then
            return 1
        fi
    done

    return 0  # Versions are equal
}

# =============================================================================
# FUNCTION: check_package_version
# =============================================================================
# Description: Check if installed package meets minimum version requirement
# Parameters:
#   $1: package_name
#   $2: min_version
# Returns: 0 if version OK or no version check needed, 1 if too old or not found
# =============================================================================
check_package_version() {
    local package_name="$1"
    local min_version="$2"

    case "$package_name" in
        docker.io|docker)
            # Get Docker version
            if ! command -v docker &>/dev/null; then
                return 1
            fi

            local docker_version
            docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)

            if [[ -z "$docker_version" ]]; then
                echo -e "${YELLOW}WARNING: Cannot determine Docker version${NC}" >&2
                return 1
            fi

            if ! version_compare "$docker_version" "$min_version"; then
                echo -e "${RED}ERROR: Docker version $docker_version is below minimum $min_version${NC}" >&2
                return 1
            fi
            ;;

        docker-compose-plugin)
            # Get docker compose version (v2 uses "docker compose" command)
            if ! docker compose version &>/dev/null 2>&1; then
                return 1
            fi

            local compose_version
            compose_version=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)

            if [[ -z "$compose_version" ]]; then
                echo -e "${YELLOW}WARNING: Cannot determine docker compose version${NC}" >&2
                return 1
            fi

            if ! version_compare "$compose_version" "$min_version"; then
                echo -e "${RED}ERROR: docker compose version $compose_version is below minimum $min_version${NC}" >&2
                return 1
            fi
            ;;

        jq)
            # Get jq version
            if ! command -v jq &>/dev/null; then
                return 1
            fi

            local jq_version
            jq_version=$(jq --version 2>/dev/null | grep -oP '\d+\.\d+' | head -n1)

            if [[ -z "$jq_version" ]]; then
                echo -e "${YELLOW}WARNING: Cannot determine jq version${NC}" >&2
                return 1
            fi

            if ! version_compare "$jq_version" "$min_version"; then
                echo -e "${RED}ERROR: jq version $jq_version is below minimum $min_version${NC}" >&2
                return 1
            fi
            ;;

        *)
            # For other packages, just check if command exists
            if ! command -v "$package_name" &>/dev/null; then
                return 1
            fi
            ;;
    esac

    return 0
}

# =============================================================================
# FUNCTION: install_package
# =============================================================================
# Description: Install a single package using detected package manager
# Parameters:
#   $1: package_name
# Returns: 0 on success, 1 on failure
# Suppresses all apt prompts (DEBIAN_FRONTEND=noninteractive)
# =============================================================================
install_package() {
    local package_name="$1"

    # Ensure PKG_MANAGER is set
    if [[ -z "${PKG_MANAGER:-}" ]]; then
        echo -e "${RED}ERROR: PKG_MANAGER not set. Run get_package_manager() first${NC}" >&2
        return 1
    fi

    # Install with noninteractive mode
    export DEBIAN_FRONTEND=noninteractive

    if ! ${PKG_MANAGER} install -y -qq "$package_name" &>/dev/null; then
        echo -e "${RED}${CROSS_MARK} Failed to install $package_name${NC}" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# FUNCTION: check_dependencies
# =============================================================================
# Description: Check if ALL required dependencies are installed
# Checks command existence and version requirements
# Returns: 0 if all present and meet version requirements, 1 if any missing
# =============================================================================
check_dependencies() {
    echo -e "${BLUE}Checking dependencies...${NC}"
    echo ""

    local missing_count=0
    local version_fail_count=0
    declare -a missing_packages=()
    declare -a version_failed_packages=()

    for package in "${REQUIRED_PACKAGES[@]}"; do
        # Check if command exists
        local cmd_name="$package"
        [[ "$package" == "docker.io" ]] && cmd_name="docker"
        [[ "$package" == "fail2ban" ]] && cmd_name="fail2ban-client"
        [[ "$package" == "dnsutils" ]] && cmd_name="dig"
        [[ "$package" == "tcpdump" ]] && cmd_name="tcpdump"
        [[ "$package" == "nmap" ]] && cmd_name="nmap"

        # Special check for docker-compose-plugin (uses "docker compose" command)
        if [[ "$package" == "docker-compose-plugin" ]]; then
            if ! docker compose version &>/dev/null 2>&1; then
                echo -e "  ${CROSS_MARK} ${package} - ${RED}NOT INSTALLED${NC}"
                missing_packages+=("$package")
                ((missing_count++)) || true
                continue
            fi
        elif ! command -v "$cmd_name" &>/dev/null; then
            echo -e "  ${CROSS_MARK} ${package} - ${RED}NOT INSTALLED${NC}"
            missing_packages+=("$package")
            ((missing_count++)) || true
            continue
        fi

        # Check version for specific packages
        local version_ok=1
        case "$package" in
            docker.io)
                if ! check_package_version "docker.io" "$DOCKER_MIN_VERSION"; then
                    version_failed_packages+=("$package (minimum: $DOCKER_MIN_VERSION)")
                    ((version_fail_count++)) || true
                    version_ok=0
                else
                    local docker_version
                    docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)
                    echo -e "  ${CHECK_MARK} ${package} - ${GREEN}installed${NC} (version: $docker_version)"
                fi
                ;;

            docker-compose-plugin)
                if ! check_package_version "docker-compose-plugin" "$DOCKER_COMPOSE_MIN_VERSION"; then
                    version_failed_packages+=("$package (minimum: $DOCKER_COMPOSE_MIN_VERSION)")
                    ((version_fail_count++)) || true
                    version_ok=0
                else
                    local compose_version
                    compose_version=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)
                    echo -e "  ${CHECK_MARK} ${package} - ${GREEN}installed${NC} (version: $compose_version)"
                fi
                ;;

            jq)
                if ! check_package_version "jq" "$JQ_MIN_VERSION"; then
                    version_failed_packages+=("$package (minimum: $JQ_MIN_VERSION)")
                    ((version_fail_count++)) || true
                    version_ok=0
                else
                    local jq_version
                    jq_version=$(jq --version 2>/dev/null | grep -oP '\d+\.\d+' | head -n1)
                    echo -e "  ${CHECK_MARK} ${package} - ${GREEN}installed${NC} (version: $jq_version)"
                fi
                ;;

            *)
                echo -e "  ${CHECK_MARK} ${package} - ${GREEN}installed${NC}"
                ;;
        esac

        if [[ $version_ok -eq 0 ]]; then
            echo -e "  ${CROSS_MARK} ${package} - ${RED}VERSION TOO OLD${NC}"
        fi
    done

    echo ""

    # Summary
    if [[ $missing_count -eq 0 ]] && [[ $version_fail_count -eq 0 ]]; then
        echo -e "${GREEN}${CHECK_MARK} All dependencies are installed and meet version requirements${NC}"
        return 0
    else
        echo -e "${YELLOW}${WARNING_MARK} Dependency check found issues:${NC}"
        echo ""

        if [[ $missing_count -gt 0 ]]; then
            echo -e "${YELLOW}  Missing packages ($missing_count):${NC}"
            for pkg in "${missing_packages[@]}"; do
                echo -e "${YELLOW}    - $pkg${NC}"
            done
            echo ""
        fi

        if [[ $version_fail_count -gt 0 ]]; then
            echo -e "${YELLOW}  Version requirements not met ($version_fail_count):${NC}"
            for pkg in "${version_failed_packages[@]}"; do
                echo -e "${YELLOW}    - $pkg${NC}"
            done
            echo ""
        fi

        # Interactive prompt to install missing packages
        echo -e "${CYAN}These packages will be installed automatically in the next step.${NC}"

        # Check for non-interactive mode via environment variable
        if [[ "${FT_AUTO_INSTALL_DEPS:-}" == "yes" ]]; then
            echo -e "${CYAN}Non-interactive mode: Auto-proceeding to installation${NC}"
            echo ""
            return 0
        fi

        echo -e "${YELLOW}Do you want to continue with automatic installation?${NC}"
        echo -e "${CYAN}  [Y/n] (30s timeout, default=yes): ${NC}"

        local user_response
        if ! read -t 30 -r user_response; then
            user_response="y"
            echo ""
            echo -e "${CYAN}Timeout reached, proceeding with installation${NC}"
        fi

        # Default to yes if empty
        [[ -z "$user_response" ]] && user_response="y"

        case "${user_response,,}" in
            n|no)
                echo -e "${RED}${CROSS_MARK} Installation cancelled by user${NC}"
                echo -e "${YELLOW}To install dependencies manually, run:${NC}"
                echo -e "${YELLOW}  sudo apt update && sudo apt install -y ${missing_packages[*]} ${version_failed_packages[*]}${NC}"
                echo ""
                return 1
                ;;
            *)
                echo -e "${GREEN}Proceeding to automatic installation...${NC}"
                echo ""
                return 0
                ;;
        esac
    fi
}

# =============================================================================
# FUNCTION: classify_apt_process
# =============================================================================
# Description: Classify APT process by safety level for automatic termination
# Parameters:
#   $1: process_name (from ps comm)
#   $2: full_command (from ps args)
# Returns: 0=SAFE (auto-kill OK), 1=CAUTION (ask user), 2=DANGER (never kill)
# Outputs: Classification to stdout (SAFE/CAUTION/DANGER)
# =============================================================================
classify_apt_process() {
    local process_name="$1"
    local full_command="${2:-}"

    # SAFE processes (can be killed automatically)
    case "$process_name" in
        apt|apt-get)
            if echo "$full_command" | grep -qE '\s+(update|search|show|list)'; then
                echo "SAFE"
                return 0
            fi
            ;;
        apt-cache)
            echo "SAFE"
            return 0
            ;;
        unattended-upgrade|unattended-upgrades)
            # Check process age - if < 5 minutes, likely safe to kill
            local pid
            pid=$(pgrep -f "$process_name" | head -n1)
            if [[ -n "$pid" ]]; then
                local age_seconds
                age_seconds=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ')
                if [[ -n "$age_seconds" ]] && [[ $age_seconds -lt 300 ]]; then
                    echo "SAFE"
                    return 0
                fi
            fi
            ;;
    esac

    # DANGER processes (never auto-kill)
    case "$process_name" in
        dpkg)
            if echo "$full_command" | grep -qE '(--install|--unpack|--configure|--remove)'; then
                echo "DANGER"
                return 2
            fi
            ;;
    esac

    # Default: CAUTION (ask user)
    echo "CAUTION"
    return 1
}

# =============================================================================
# FUNCTION: check_apt_locks
# =============================================================================
# Description: Check if APT package manager is locked by another process
# Checks all common lock files used by apt/dpkg
# Returns: 0 if no locks detected, 1 if locks found
# Sets global arrays: LOCK_PIDS, LOCK_PROCESSES, LOCK_CLASSIFICATIONS
# =============================================================================
check_apt_locks() {
    local locks=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )

    local locks_found=0
    declare -ga LOCK_PIDS=()
    declare -ga LOCK_PROCESSES=()
    declare -ga LOCK_CLASSIFICATIONS=()

    for lock in "${locks[@]}"; do
        # Check if lock file is held by a process
        if command -v fuser &>/dev/null && fuser "$lock" &>/dev/null 2>&1; then
            local pid
            pid=$(fuser "$lock" 2>/dev/null | awk '{print $1}')

            if [[ -n "$pid" ]]; then
                # Skip duplicates
                if [[ " ${LOCK_PIDS[*]} " =~ " ${pid} " ]]; then
                    continue
                fi

                local process_name
                process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")

                local full_cmd
                full_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")

                local classification
                classification=$(classify_apt_process "$process_name" "$full_cmd")

                LOCK_PIDS+=("$pid")
                LOCK_PROCESSES+=("$process_name")
                LOCK_CLASSIFICATIONS+=("$classification")

                echo -e "${YELLOW}${WARNING_MARK} APT lock detected: $lock${NC}" >&2
                echo -e "${YELLOW}  Process: $process_name (PID: $pid)${NC}" >&2
                echo -e "${YELLOW}  Classification: $classification${NC}" >&2

                if [[ -n "$full_cmd" ]]; then
                    echo -e "${YELLOW}  Command: ${full_cmd:0:80}${NC}" >&2
                fi

                locks_found=1
            fi
        fi
    done

    return $locks_found
}

# =============================================================================
# FUNCTION: diagnose_apt_locks
# =============================================================================
# Description: Provide detailed diagnostics when APT is locked
# Shows all processes holding locks and suggests solutions
# =============================================================================
diagnose_apt_locks() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           APT LOCK DIAGNOSTICS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local locks=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )

    echo -e "${CYAN}Checking APT lock files...${NC}"
    echo ""

    local found_processes=0

    for lock in "${locks[@]}"; do
        if command -v fuser &>/dev/null && fuser "$lock" &>/dev/null 2>&1; then
            local pid
            pid=$(fuser "$lock" 2>/dev/null | awk '{print $1}')

            if [[ -n "$pid" ]]; then
                found_processes=1

                echo -e "${YELLOW}Lock: $lock${NC}"
                echo -e "${YELLOW}  PID: $pid${NC}"
                echo -e "${YELLOW}  Process: $(ps -p "$pid" -o comm= 2>/dev/null || echo 'unknown')${NC}"
                echo -e "${YELLOW}  Command: $(ps -p "$pid" -o args= 2>/dev/null || echo 'unknown')${NC}"
                echo -e "${YELLOW}  Started: $(ps -p "$pid" -o lstart= 2>/dev/null || echo 'unknown')${NC}"
                echo ""
            fi
        fi
    done

    if [[ $found_processes -eq 0 ]]; then
        echo -e "${GREEN}${CHECK_MARK} No active locks detected${NC}"
        echo ""
        return 0
    fi

    # Check for common processes
    echo -e "${CYAN}Common Causes & Solutions:${NC}"
    echo ""

    if pgrep -f "unattended.*upgrade" &>/dev/null; then
        echo -e "${YELLOW}1. Automatic Updates Running${NC}"
        echo -e "   ${CYAN}Wait for completion: sudo systemctl status unattended-upgrades${NC}"
        echo -e "   ${CYAN}Check progress: sudo tail -f /var/log/unattended-upgrades/unattended-upgrades.log${NC}"
        echo ""
    fi

    if pgrep -f "apt|dpkg" &>/dev/null; then
        echo -e "${YELLOW}2. Manual APT Process Running${NC}"
        echo -e "   ${CYAN}Check all apt processes: ps aux | grep -E 'apt|dpkg'${NC}"
        echo -e "   ${CYAN}Wait for completion or check other terminals${NC}"
        echo ""
    fi

    echo -e "${YELLOW}3. General Solutions (in order of safety):${NC}"
    echo -e "   ${CYAN}a) Wait 2-5 minutes for automatic processes to finish (RECOMMENDED)${NC}"
    echo -e "   ${CYAN}b) Check if process is stuck: ps -p <PID> -o etime=,stat=,cmd=${NC}"
    echo -e "   ${CYAN}c) Kill stuck process (CAUTION): sudo kill <PID>${NC}"
    echo -e "   ${CYAN}d) Force kill if needed: sudo kill -9 <PID>${NC}"
    echo -e "   ${RED}e) Remove stale locks (LAST RESORT, may break system):${NC}"
    echo -e "   ${RED}   sudo rm /var/lib/apt/lists/lock${NC}"
    echo -e "   ${RED}   sudo rm /var/lib/dpkg/lock*${NC}"
    echo -e "   ${RED}   sudo dpkg --configure -a${NC}"
    echo ""

    return 1
}

# =============================================================================
# FUNCTION: kill_safe_apt_processes
# =============================================================================
# Description: Automatically kill SAFE APT processes (apt update, apt-cache, etc.)
# Uses global arrays from check_apt_locks(): LOCK_PIDS, LOCK_PROCESSES, LOCK_CLASSIFICATIONS
# Returns: 0 if any processes killed, 1 if none killed
# =============================================================================
kill_safe_apt_processes() {
    local killed_count=0
    local danger_count=0
    local caution_count=0

    if [[ ${#LOCK_PIDS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No lock processes to terminate${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}Analyzing blocking processes for safe termination...${NC}"
    echo ""

    for i in "${!LOCK_PIDS[@]}"; do
        local pid="${LOCK_PIDS[$i]}"
        local process="${LOCK_PROCESSES[$i]}"
        local classification="${LOCK_CLASSIFICATIONS[$i]}"

        case "$classification" in
            SAFE)
                echo -e "  ${GREEN}[SAFE]${NC} Terminating $process (PID $pid)..."

                if kill "$pid" 2>/dev/null; then
                    echo -e "  ${GREEN}${CHECK_MARK} Process $pid terminated${NC}"
                    ((killed_count++)) || true
                    sleep 1
                else
                    echo -e "  ${YELLOW}${WARNING_MARK} Failed to kill $pid, trying force kill...${NC}"
                    if kill -9 "$pid" 2>/dev/null; then
                        echo -e "  ${GREEN}${CHECK_MARK} Process $pid force-killed${NC}"
                        ((killed_count++)) || true
                        sleep 1
                    else
                        echo -e "  ${RED}${CROSS_MARK} Cannot kill process $pid${NC}"
                    fi
                fi
                ;;

            DANGER)
                echo -e "  ${RED}[DANGER]${NC} Skipping $process (PID $pid) - unsafe to terminate"
                ((danger_count++)) || true
                ;;

            CAUTION)
                echo -e "  ${YELLOW}[CAUTION]${NC} Skipping $process (PID $pid) - requires user confirmation"
                ((caution_count++)) || true
                ;;
        esac
    done

    echo ""

    if [[ $killed_count -gt 0 ]]; then
        echo -e "${GREEN}${CHECK_MARK} Terminated $killed_count safe process(es)${NC}"

        # Clean up potential stale locks after killing processes
        echo -e "${CYAN}Cleaning up package manager state...${NC}"
        sudo dpkg --configure -a &>/dev/null 2>&1 || true

        return 0
    elif [[ $danger_count -gt 0 ]] || [[ $caution_count -gt 0 ]]; then
        echo -e "${YELLOW}${WARNING_MARK} No safe processes to auto-terminate${NC}"
        echo -e "${YELLOW}  DANGER processes: $danger_count${NC}"
        echo -e "${YELLOW}  CAUTION processes: $caution_count${NC}"
        echo -e "${YELLOW}  Manual intervention required${NC}"
        return 1
    else
        echo -e "${YELLOW}${WARNING_MARK} No processes to terminate${NC}"
        return 1
    fi
}

# =============================================================================
# FUNCTION: install_dependencies
# =============================================================================
# Description: Auto-install ALL missing dependencies
# Uses apt update before installation with retry mechanism
# Installs dependencies one by one with progress indicators
# Validates each installation after completion
# Includes APT lock detection and handling with SAFE auto-kill
# ENV variables:
#   - FT_AUTO_INSTALL_DEPS=yes: Skip user prompts for dependency installation
#   - FT_AUTO_KILL_SAFE_LOCKS=yes: Auto-kill SAFE blocking processes
# Returns: 0 on success, 1 on failure
# =============================================================================
install_dependencies() {
    echo -e "${BLUE}Installing missing dependencies...${NC}"
    echo ""

    # Ensure PKG_MANAGER is set
    if [[ -z "${PKG_MANAGER:-}" ]]; then
        echo -e "${RED}ERROR: PKG_MANAGER not set. Run get_package_manager() first${NC}" >&2
        return 1
    fi

    # Update package lists with retry mechanism and lock detection
    echo -e "${CYAN}Updating package lists...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    local max_attempts=5
    local wait_time=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        # Try apt update
        if ${PKG_MANAGER} update -qq &>/dev/null 2>&1; then
            echo -e "${GREEN}${CHECK_MARK} Package lists updated${NC}"
            echo ""
            break
        fi

        # Check if failure is due to APT lock
        if check_apt_locks; then
            # Not a lock issue, some other problem
            echo -e "${RED}${CROSS_MARK} Failed to update package lists${NC}" >&2
            echo -e "${YELLOW}Suggestion: Check internet connection and run 'sudo ${PKG_MANAGER} update' manually${NC}" >&2
            return 1
        fi

        # APT is locked - try automatic safe kill first
        echo ""

        # Check if auto-kill is enabled
        if [[ "${FT_AUTO_KILL_SAFE_LOCKS:-}" == "yes" ]]; then
            echo -e "${CYAN}Auto-kill mode enabled. Attempting safe process termination...${NC}"
            echo ""

            if kill_safe_apt_processes; then
                echo ""
                echo -e "${GREEN}Safe processes terminated. Retrying apt update...${NC}"
                ((attempt++)) || true
                sleep 2
                continue
            else
                echo ""
                echo -e "${YELLOW}Cannot auto-kill remaining processes. Manual intervention needed.${NC}"
                diagnose_apt_locks
                return 1
            fi
        fi

        # Not auto-kill mode - show diagnostics
        diagnose_apt_locks

        # Interactive prompt for user action
        if [[ $attempt -lt $max_attempts ]]; then
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}APT is locked. Choose an action:${NC}"
            echo -e "  ${CYAN}[w]${NC} Wait ${wait_time}s and retry (attempt $attempt/$max_attempts)"
            echo -e "  ${CYAN}[a]${NC} Auto-kill SAFE processes only (recommended)"
            echo -e "  ${CYAN}[k]${NC} Kill ALL blocking processes (CAUTION)"
            echo -e "  ${CYAN}[c]${NC} Cancel installation"
            echo ""
            echo -e "${CYAN}Your choice [w/a/k/c] (default=wait, 60s timeout): ${NC}"

            local user_choice
            if ! read -t 60 -r user_choice; then
                user_choice="w"
                echo ""
                echo -e "${CYAN}Timeout reached, waiting for lock to release...${NC}"
            fi

            # Default to wait if empty
            [[ -z "$user_choice" ]] && user_choice="w"

            case "${user_choice,,}" in
                a|auto)
                    echo ""
                    if kill_safe_apt_processes; then
                        echo ""
                        echo -e "${CYAN}Retrying apt update...${NC}"
                        ((attempt++)) || true
                        sleep 2
                        continue
                    else
                        echo -e "${RED}${CROSS_MARK} No safe processes to kill${NC}"
                        return 1
                    fi
                    ;;

                k|kill)
                    echo ""
                    echo -e "${RED}${WARNING_MARK} WARNING: Killing ALL blocking processes (including potentially unsafe)${NC}"
                    echo -e "${YELLOW}This may damage your system if dpkg is in the middle of package installation!${NC}"
                    echo ""
                    echo -e "${CYAN}Type 'yes' to confirm force kill: ${NC}"

                    local confirm
                    if ! read -t 30 -r confirm; then
                        echo ""
                        echo -e "${YELLOW}Timeout - cancelling force kill${NC}"
                        continue
                    fi

                    if [[ "${confirm,,}" != "yes" ]] && [[ "${confirm,,}" != "y" ]]; then
                        echo -e "${YELLOW}Force kill cancelled${NC}"
                        continue
                    fi

                    echo -e "${YELLOW}Force killing ALL processes...${NC}"

                    local locks=(
                        "/var/lib/dpkg/lock"
                        "/var/lib/dpkg/lock-frontend"
                        "/var/lib/apt/lists/lock"
                        "/var/cache/apt/archives/lock"
                    )

                    local killed_any=0

                    for lock in "${locks[@]}"; do
                        if command -v fuser &>/dev/null && fuser "$lock" &>/dev/null 2>&1; then
                            local pid
                            pid=$(fuser "$lock" 2>/dev/null | awk '{print $1}')

                            if [[ -n "$pid" ]]; then
                                echo -e "  Killing PID $pid ($(ps -p "$pid" -o comm= 2>/dev/null))..."

                                if kill "$pid" 2>/dev/null; then
                                    echo -e "  ${GREEN}${CHECK_MARK} Process $pid terminated${NC}"
                                    killed_any=1
                                    sleep 2
                                else
                                    echo -e "  ${YELLOW}${WARNING_MARK} Failed to kill $pid, trying force kill...${NC}"
                                    if kill -9 "$pid" 2>/dev/null; then
                                        echo -e "  ${GREEN}${CHECK_MARK} Process $pid force-killed${NC}"
                                        killed_any=1
                                        sleep 2
                                    else
                                        echo -e "  ${RED}${CROSS_MARK} Cannot kill process $pid${NC}"
                                    fi
                                fi
                            fi
                        fi
                    done

                    if [[ $killed_any -eq 1 ]]; then
                        echo ""
                        echo -e "${GREEN}Processes terminated. Cleaning up and retrying...${NC}"

                        # Clean up potential stale locks
                        sudo dpkg --configure -a &>/dev/null || true

                        echo -e "${CYAN}Retrying apt update...${NC}"
                        ((attempt++)) || true
                        continue
                    else
                        echo -e "${RED}${CROSS_MARK} No processes were killed${NC}"
                        return 1
                    fi
                    ;;

                c|cancel)
                    echo ""
                    echo -e "${RED}${CROSS_MARK} Installation cancelled by user${NC}"
                    return 1
                    ;;

                w|wait|*)
                    echo ""
                    echo -e "${CYAN}⏳ Waiting ${wait_time}s for APT lock to release (attempt $attempt/$max_attempts)...${NC}"
                    sleep $wait_time
                    ((attempt++)) || true
                    continue
                    ;;
            esac
        else
            # Last attempt failed
            echo ""
            echo -e "${RED}${CROSS_MARK} APT lock timeout after $max_attempts attempts${NC}"
            echo -e "${YELLOW}Please resolve the APT lock manually and retry installation${NC}"
            return 1
        fi
    done

    # Setup Docker official repository for docker-compose-plugin
    # This must be done before installing docker-compose-plugin package
    echo ""
    echo -e "${CYAN}Checking Docker repository configuration...${NC}"
    if ! setup_docker_repository; then
        echo -e "${YELLOW}${WARNING_MARK} Docker repository setup failed${NC}"
        echo -e "${YELLOW}docker-compose-plugin installation may fail${NC}"
        echo ""
        echo -e "${CYAN}Manual setup instructions:${NC}"
        echo -e "${CYAN}  1. Add Docker GPG key: curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg${NC}"
        echo -e "${CYAN}  2. Add repository: echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list${NC}"
        echo -e "${CYAN}  3. Update packages: sudo ${PKG_MANAGER} update${NC}"
        echo -e "${CYAN}  4. Retry installation: sudo ./install.sh${NC}"
        echo ""

        # Ask user if they want to continue without docker-compose-plugin
        if [[ "${FT_AUTO_INSTALL_DEPS:-}" != "yes" ]]; then
            echo -e "${YELLOW}Continue installation without docker-compose-plugin? [y/N]: ${NC}"
            local user_response
            if ! read -t 30 -r user_response; then
                user_response="n"
                echo ""
            fi

            case "${user_response,,}" in
                y|yes)
                    echo -e "${YELLOW}Continuing without docker-compose-plugin (will be skipped)${NC}"
                    echo ""
                    ;;
                *)
                    echo -e "${RED}${CROSS_MARK} Installation cancelled${NC}"
                    return 1
                    ;;
            esac
        fi
    fi
    echo ""

    # Get total package count (using ${#array[@]:-} would be invalid for arrays)
    # Ensure REQUIRED_PACKAGES is accessible from global scope
    local total_packages=${#REQUIRED_PACKAGES[@]}
    local installed_count=0
    local failed_count=0
    local -a failed_packages=()

    for i in "${!REQUIRED_PACKAGES[@]}"; do
        local package="${REQUIRED_PACKAGES[$i]}"
        local current_num=$((i + 1))

        # Check if already installed
        local cmd_name="$package"
        [[ "$package" == "docker.io" ]] && cmd_name="docker"
        [[ "$package" == "netcat-openbsd" ]] && cmd_name="nc"
        [[ "$package" == "fail2ban" ]] && cmd_name="fail2ban-server"
        [[ "$package" == "dnsutils" ]] && cmd_name="dig"
        [[ "$package" == "tcpdump" ]] && cmd_name="tcpdump"
        [[ "$package" == "nmap" ]] && cmd_name="nmap"

        # Special check for docker-compose-plugin
        local is_installed=false
        if [[ "$package" == "docker-compose-plugin" ]]; then
            if docker compose version &>/dev/null 2>&1; then
                is_installed=true
            fi
        elif command -v "$cmd_name" &>/dev/null; then
            is_installed=true
        fi

        if [[ "$is_installed" == "true" ]]; then
            # Check version for specific packages
            case "$package" in
                docker.io)
                    if check_package_version "docker.io" "$DOCKER_MIN_VERSION"; then
                        echo -e "[$current_num/$total_packages] ${CHECK_MARK} $package - ${GREEN}already installed${NC}"
                        ((installed_count++)) || true
                        continue
                    fi
                    ;;
                docker-compose-plugin)
                    if check_package_version "docker-compose-plugin" "$DOCKER_COMPOSE_MIN_VERSION"; then
                        echo -e "[$current_num/$total_packages] ${CHECK_MARK} $package - ${GREEN}already installed${NC}"
                        ((installed_count++)) || true
                        continue
                    fi
                    ;;
                jq)
                    if check_package_version "jq" "$JQ_MIN_VERSION"; then
                        echo -e "[$current_num/$total_packages] ${CHECK_MARK} $package - ${GREEN}already installed${NC}"
                        ((installed_count++)) || true
                        continue
                    fi
                    ;;
                *)
                    echo -e "[$current_num/$total_packages] ${CHECK_MARK} $package - ${GREEN}already installed${NC}"
                    ((installed_count++)) || true
                    continue
                    ;;
            esac
        fi

        # Install package
        echo -e "[$current_num/$total_packages] Installing $package..."

        if install_package "$package"; then
            # Validate installation
            local is_installed=false

            # Special check for docker-compose-plugin (uses "docker compose" command)
            if [[ "$package" == "docker-compose-plugin" ]]; then
                if docker compose version &>/dev/null 2>&1; then
                    is_installed=true
                fi
            elif command -v "$cmd_name" &>/dev/null; then
                is_installed=true
            fi

            if [[ "$is_installed" == "true" ]]; then
                echo -e "[$current_num/$total_packages] ${CHECK_MARK} $package - ${GREEN}installed successfully${NC}"
                ((installed_count++)) || true

                # Special handling for Docker
                if [[ "$package" == "docker.io" ]]; then
                    echo -e "  ${CYAN}Enabling and starting Docker service...${NC}"
                    if start_docker_service; then
                        echo -e "  ${GREEN}${CHECK_MARK} Docker service started${NC}"
                    else
                        echo -e "  ${YELLOW}${WARNING_MARK} Docker service may need manual start${NC}"
                    fi
                fi
            else
                echo -e "[$current_num/$total_packages] ${CROSS_MARK} $package - ${RED}installation verification failed${NC}"
                failed_packages+=("$package")
                ((failed_count++)) || true
            fi
        else
            # Special handling for docker-compose-plugin failure
            if [[ "$package" == "docker-compose-plugin" ]]; then
                echo -e "[$current_num/$total_packages] ${CROSS_MARK} $package - ${RED}installation failed${NC}"
                echo -e "  ${YELLOW}${WARNING_MARK} Attempting fallback to standalone docker-compose...${NC}"

                # Try to install standalone docker-compose binary
                if command -v docker-compose &>/dev/null; then
                    echo -e "  ${GREEN}${CHECK_MARK} docker-compose standalone already available${NC}"
                    ((installed_count++)) || true
                elif install_package "docker-compose" 2>/dev/null; then
                    if command -v docker-compose &>/dev/null; then
                        echo -e "  ${GREEN}${CHECK_MARK} docker-compose standalone installed successfully${NC}"
                        ((installed_count++)) || true
                    else
                        echo -e "  ${YELLOW}${WARNING_MARK} Fallback failed - docker-compose not available${NC}"
                        echo -e "  ${CYAN}System will use 'docker compose' syntax if available${NC}"
                        failed_packages+=("$package")
                        ((failed_count++)) || true
                    fi
                else
                    echo -e "  ${YELLOW}${WARNING_MARK} Fallback failed - will use 'docker compose' if available${NC}"
                    failed_packages+=("$package")
                    ((failed_count++)) || true
                fi
            else
                echo -e "[$current_num/$total_packages] ${CROSS_MARK} $package - ${RED}installation failed${NC}"
                failed_packages+=("$package")
                ((failed_count++)) || true
            fi
        fi
    done

    # Install optional packages (v3.2)
    echo ""
    echo -e "${CYAN}Installing optional packages...${NC}"

    for package in "${OPTIONAL_PACKAGES[@]}"; do
        # Map package name to command name
        local opt_cmd="$package"
        [[ "$package" == "netcat-openbsd" ]] && opt_cmd="nc"
        [[ "$package" == "tshark" ]] && opt_cmd="tshark"

        # Check if already installed
        if command -v "$opt_cmd" &>/dev/null 2>&1; then
            echo -e "  ${CHECK_MARK} $package - ${GREEN}already installed${NC}"
            continue
        fi

        # Try to install
        echo -e "  Installing $package..."
        if install_package "$package"; then
            if command -v "$opt_cmd" &>/dev/null 2>&1; then
                echo -e "  ${CHECK_MARK} $package - ${GREEN}installed successfully${NC}"
            else
                echo -e "  ${YELLOW}${WARNING_MARK} $package - installed but command not found${NC}"
            fi
        else
            # Handle fallbacks for specific packages
            if [[ "$package" == "netcat-openbsd" ]]; then
                echo -e "  ${YELLOW}${WARNING_MARK} netcat-openbsd not available, trying alternatives...${NC}"

                # Try netcat-traditional
                if install_package "netcat-traditional" 2>/dev/null; then
                    echo -e "  ${CHECK_MARK} netcat-traditional - ${GREEN}installed as fallback${NC}"
                # Try ncat (from nmap package)
                elif command -v ncat &>/dev/null 2>&1; then
                    echo -e "  ${CHECK_MARK} ncat - ${GREEN}already available${NC}"
                else
                    echo -e "  ${YELLOW}${WARNING_MARK} No netcat variant available (healthchecks will be disabled)${NC}"
                fi
            elif [[ "$package" == "tshark" ]]; then
                echo -e "  ${YELLOW}${WARNING_MARK} tshark not available (advanced packet analysis disabled)${NC}"
                echo -e "  ${CYAN}Note: tshark is part of Wireshark package (large download)${NC}"
                echo -e "  ${CYAN}Manual install: sudo apt-get install tshark${NC}"
            elif [[ "$package" == "fail2ban" ]]; then
                echo -e "  ${YELLOW}${WARNING_MARK} $package - installation failed (will be handled by fail2ban_setup.sh)${NC}"
            else
                echo -e "  ${YELLOW}${WARNING_MARK} $package - installation failed (non-critical)${NC}"
            fi
        fi
    done

    echo ""
    echo -e "${BLUE}Installation Summary:${NC}"
    echo -e "  Total packages: $total_packages"
    echo -e "  Successfully installed: $installed_count"
    echo -e "  Failed: $failed_count"

    if [[ $failed_count -gt 0 ]]; then
        echo ""
        echo -e "${RED}${CROSS_MARK} Failed to install the following packages:${NC}"
        for pkg in "${failed_packages[@]}"; do
            echo -e "${RED}  - $pkg${NC}"
        done
        echo ""
        echo -e "${YELLOW}Suggestion: Try installing manually with:${NC}"
        echo -e "${YELLOW}  sudo ${PKG_MANAGER} install ${failed_packages[*]}${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}${CHECK_MARK} All dependencies installed successfully${NC}"
    return 0
}

# =============================================================================
# FUNCTION: start_docker_service
# =============================================================================
# Description: Enable and start Docker service
# Waits for Docker to be fully ready
# Returns: 0 on success, 1 on failure
# =============================================================================
start_docker_service() {
    # Check if systemctl is available
    if ! command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}WARNING: systemctl not found, cannot manage Docker service${NC}" >&2
        return 1
    fi

    # Enable Docker service (persist across reboots)
    if ! systemctl enable docker &>/dev/null; then
        echo -e "${YELLOW}WARNING: Failed to enable Docker service${NC}" >&2
    fi

    # Start Docker service
    if ! systemctl start docker &>/dev/null; then
        echo -e "${RED}ERROR: Failed to start Docker service${NC}" >&2
        echo -e "${YELLOW}Suggestion: Check Docker installation with 'systemctl status docker'${NC}" >&2
        return 1
    fi

    # Wait for Docker to be ready (max 30 seconds)
    local max_wait=30
    local waited=0

    while ! docker ps &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            echo -e "${RED}ERROR: Docker did not become ready within ${max_wait}s${NC}" >&2
            return 1
        fi
        sleep 1
        ((waited++)) || true
    done

    return 0
}

# =============================================================================
# FUNCTION: check_docker_repository_configured
# =============================================================================
# Description: Check if official Docker APT repository is already configured
# Returns: 0 if configured, 1 if not configured
# =============================================================================
check_docker_repository_configured() {
    # Check if docker repository source file exists
    local docker_sources=(
        "/etc/apt/sources.list.d/docker.list"
        "/etc/apt/sources.list.d/docker-ce.list"
    )

    for source in "${docker_sources[@]}"; do
        if [[ -f "$source" ]] && grep -q "download.docker.com" "$source" 2>/dev/null; then
            return 0
        fi
    done

    # Also check main sources.list
    if grep -q "download.docker.com" /etc/apt/sources.list 2>/dev/null; then
        return 0
    fi

    return 1
}

# =============================================================================
# FUNCTION: setup_docker_repository
# =============================================================================
# Description: Add official Docker APT repository for docker-compose-plugin
# Supports: Ubuntu 20.04+, Debian 10+
# Returns: 0 on success, 1 on failure
# Side effects: Adds Docker GPG key and APT repository
# =============================================================================
setup_docker_repository() {
    echo -e "${CYAN}Setting up Docker official APT repository...${NC}"
    echo ""

    # Check if already configured
    if check_docker_repository_configured; then
        echo -e "${GREEN}${CHECK_MARK} Docker repository already configured${NC}"
        return 0
    fi

    # Ensure prerequisites are installed
    echo -e "${CYAN}[1/5] Installing prerequisites...${NC}"
    local prerequisites=(
        "ca-certificates"
        "gnupg"
        "lsb-release"
    )

    export DEBIAN_FRONTEND=noninteractive

    for pkg in "${prerequisites[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            if ! ${PKG_MANAGER} install -y -qq "$pkg" &>/dev/null; then
                echo -e "${RED}${CROSS_MARK} Failed to install prerequisite: $pkg${NC}" >&2
                return 1
            fi
        fi
    done
    echo -e "${GREEN}${CHECK_MARK} Prerequisites installed${NC}"

    # Create keyrings directory
    echo -e "${CYAN}[2/5] Creating keyrings directory...${NC}"
    mkdir -p /etc/apt/keyrings
    chmod 755 /etc/apt/keyrings
    echo -e "${GREEN}${CHECK_MARK} Keyrings directory ready${NC}"

    # Add Docker GPG key
    echo -e "${CYAN}[3/5] Adding Docker GPG key...${NC}"
    local gpg_key_url="https://download.docker.com/linux/${OS_ID}/gpg"
    local gpg_key_file="/etc/apt/keyrings/docker.gpg"

    # Remove old key if exists
    rm -f "$gpg_key_file"

    # Download and add GPG key
    if ! curl -fsSL "$gpg_key_url" | gpg --dearmor -o "$gpg_key_file" 2>/dev/null; then
        echo -e "${RED}${CROSS_MARK} Failed to download Docker GPG key${NC}" >&2
        echo -e "${YELLOW}Suggestion: Check internet connection to download.docker.com${NC}" >&2
        return 1
    fi

    chmod 644 "$gpg_key_file"
    echo -e "${GREEN}${CHECK_MARK} Docker GPG key added${NC}"

    # Detect OS version for repository URL
    echo -e "${CYAN}[4/5] Configuring repository for ${OS_NAME} ${OS_VERSION}...${NC}"

    # Get architecture
    local arch
    arch=$(dpkg --print-architecture)

    # Get version codename
    local version_codename
    version_codename=$(lsb_release -cs)

    # Create repository entry
    local repo_file="/etc/apt/sources.list.d/docker.list"
    local repo_url="https://download.docker.com/linux/${OS_ID}"

    # Write repository configuration
    cat > "$repo_file" << EOF
# Docker Official Repository
deb [arch=${arch} signed-by=${gpg_key_file}] ${repo_url} ${version_codename} stable
EOF

    chmod 644 "$repo_file"
    echo -e "${GREEN}${CHECK_MARK} Repository configured: $repo_file${NC}"
    echo -e "${CYAN}  Architecture: ${arch}${NC}"
    echo -e "${CYAN}  Codename: ${version_codename}${NC}"

    # Update package lists
    echo -e "${CYAN}[5/5] Updating package lists...${NC}"
    if ! ${PKG_MANAGER} update -qq &>/dev/null 2>&1; then
        echo -e "${RED}${CROSS_MARK} Failed to update package lists after adding repository${NC}" >&2
        echo -e "${YELLOW}Suggestion: Check repository configuration in $repo_file${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}${CHECK_MARK} Package lists updated${NC}"

    echo ""
    echo -e "${GREEN}${CHECK_MARK} Docker repository setup complete${NC}"
    return 0
}

# =============================================================================
# FUNCTION: validate_docker - EXTENDED DIAGNOSTICS (Q-A3)
# =============================================================================
# Description: Comprehensive Docker validation with extended diagnostics
# Checks:
#   1. Docker version >= 20.10
#   2. /var/run/docker.sock exists and is accessible
#   3. Current user in docker group (if not root)
#   4. Docker daemon is running
#   5. Can run simple test container (docker run hello-world)
#   6. docker-compose version >= 1.29
# Returns: 0 if all checks pass, 1 if any fail
# =============================================================================
validate_docker() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           EXTENDED DOCKER DIAGNOSTICS                         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local check_count=0
    local failed_count=0
    declare -a failed_checks=()

    # -------------------------------------------------------------------------
    # CHECK 1: Docker Version >= 20.10
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[1/6] Checking Docker version...${NC}"

    if ! command -v docker &>/dev/null; then
        echo -e "${RED}  ${CROSS_MARK} Docker command not found${NC}"
        failed_checks+=("Docker not installed")
        ((failed_count++)) || true
    else
        local docker_version
        docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)

        if [[ -z "$docker_version" ]]; then
            echo -e "${RED}  ${CROSS_MARK} Cannot determine Docker version${NC}"
            failed_checks+=("Docker version unknown")
            ((failed_count++)) || true
        elif ! version_compare "$docker_version" "$DOCKER_MIN_VERSION"; then
            echo -e "${RED}  ${CROSS_MARK} Docker version $docker_version is below minimum $DOCKER_MIN_VERSION${NC}"
            echo -e "${YELLOW}  Suggestion: Upgrade Docker with 'sudo apt-get install --only-upgrade docker.io'${NC}"
            failed_checks+=("Docker version too old: $docker_version")
            ((failed_count++)) || true
        else
            echo -e "${GREEN}  ${CHECK_MARK} Docker version: $docker_version (meets minimum $DOCKER_MIN_VERSION)${NC}"
        fi
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 2: Docker Socket Exists and Accessible
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[2/6] Checking Docker socket...${NC}"

    local socket_path="/var/run/docker.sock"

    if [[ ! -S "$socket_path" ]]; then
        echo -e "${RED}  ${CROSS_MARK} Docker socket not found at $socket_path${NC}"
        echo -e "${YELLOW}  Suggestion: Start Docker service with 'sudo systemctl start docker'${NC}"
        failed_checks+=("Docker socket missing")
        ((failed_count++)) || true
    elif [[ ! -r "$socket_path" ]]; then
        echo -e "${RED}  ${CROSS_MARK} Docker socket exists but is not readable${NC}"
        echo -e "${YELLOW}  Suggestion: Add current user to docker group or run as root${NC}"
        failed_checks+=("Docker socket not readable")
        ((failed_count++)) || true
    elif [[ ! -w "$socket_path" ]]; then
        echo -e "${YELLOW}  ${WARNING_MARK} Docker socket is read-only (may need sudo)${NC}"
        echo -e "${GREEN}  ${CHECK_MARK} Socket exists at $socket_path${NC}"
    else
        echo -e "${GREEN}  ${CHECK_MARK} Docker socket accessible at $socket_path${NC}"

        # Show socket permissions
        local socket_perms
        socket_perms=$(ls -l "$socket_path" | awk '{print $1, $3, $4}')
        echo -e "${CYAN}  Permissions: $socket_perms${NC}"
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 3: User in Docker Group (if not root)
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[3/6] Checking Docker group membership...${NC}"

    if [[ $EUID -eq 0 ]]; then
        echo -e "${GREEN}  ${CHECK_MARK} Running as root (Docker group check skipped)${NC}"
    else
        local current_user
        current_user=$(whoami)

        if groups "$current_user" | grep -q '\bdocker\b'; then
            echo -e "${GREEN}  ${CHECK_MARK} User '$current_user' is in docker group${NC}"
        else
            echo -e "${YELLOW}  ${WARNING_MARK} User '$current_user' is NOT in docker group${NC}"
            echo -e "${YELLOW}  Current groups: $(groups "$current_user")${NC}"
            echo ""
            echo -e "${CYAN}  To add user to docker group:${NC}"
            echo -e "${CYAN}    sudo usermod -aG docker $current_user${NC}"
            echo -e "${CYAN}    newgrp docker  # Or logout and login again${NC}"
            echo ""
            echo -e "${YELLOW}  ${WARNING_MARK} You may need to re-login for group changes to take effect${NC}"
            # This is a warning, not a failure
        fi
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 4: Docker Daemon Running
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[4/6] Checking Docker daemon status...${NC}"

    if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo -e "${RED}  ${CROSS_MARK} Docker daemon is not running${NC}"
        echo -e "${YELLOW}  Suggestion: Start Docker with 'sudo systemctl start docker'${NC}"

        # Try to show systemctl status
        if command -v systemctl &>/dev/null; then
            echo -e "${CYAN}  Docker service status:${NC}"
            systemctl status docker --no-pager -l | head -n 10 | sed 's/^/    /'
        fi

        failed_checks+=("Docker daemon not running")
        ((failed_count++)) || true
    else
        echo -e "${GREEN}  ${CHECK_MARK} Docker daemon is running${NC}"

        # Show uptime
        local docker_uptime
        docker_uptime=$(systemctl show docker --property=ActiveEnterTimestamp --value 2>/dev/null)
        if [[ -n "$docker_uptime" ]]; then
            echo -e "${CYAN}  Started: $docker_uptime${NC}"
        fi
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 5: Test Container Run
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[5/6] Testing Docker with hello-world container...${NC}"

    # Clean up any previous hello-world containers
    docker rm -f hello-world-test &>/dev/null || true

    # Run test container
    local test_output
    if test_output=$(docker run --rm --name hello-world-test hello-world 2>&1); then
        echo -e "${GREEN}  ${CHECK_MARK} Successfully ran test container${NC}"
        echo -e "${CYAN}  Container output (first 3 lines):${NC}"
        echo "$test_output" | head -n 3 | sed 's/^/    /'
    else
        echo -e "${RED}  ${CROSS_MARK} Failed to run test container${NC}"
        echo -e "${CYAN}  Error output:${NC}"
        echo "$test_output" | head -n 5 | sed 's/^/    /'

        failed_checks+=("Docker test container failed")
        ((failed_count++)) || true
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # CHECK 6: docker-compose Version >= 1.29
    # -------------------------------------------------------------------------
    echo -e "${CYAN}[6/6] Checking docker-compose version...${NC}"

    if ! command -v docker-compose &>/dev/null; then
        echo -e "${RED}  ${CROSS_MARK} docker-compose command not found${NC}"
        failed_checks+=("docker-compose not installed")
        ((failed_count++)) || true
    else
        local compose_version
        compose_version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)

        if [[ -z "$compose_version" ]]; then
            echo -e "${RED}  ${CROSS_MARK} Cannot determine docker-compose version${NC}"
            failed_checks+=("docker-compose version unknown")
            ((failed_count++)) || true
        elif ! version_compare "$compose_version" "$DOCKER_COMPOSE_MIN_VERSION"; then
            echo -e "${RED}  ${CROSS_MARK} docker-compose version $compose_version is below minimum $DOCKER_COMPOSE_MIN_VERSION${NC}"
            echo -e "${YELLOW}  Suggestion: Upgrade docker-compose with 'sudo apt-get install --only-upgrade docker-compose'${NC}"
            failed_checks+=("docker-compose version too old: $compose_version")
            ((failed_count++)) || true
        else
            echo -e "${GREEN}  ${CHECK_MARK} docker-compose version: $compose_version (meets minimum $DOCKER_COMPOSE_MIN_VERSION)${NC}"
        fi
    fi
    ((check_count++)) || true
    echo ""

    # -------------------------------------------------------------------------
    # SUMMARY
    # -------------------------------------------------------------------------
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           DOCKER VALIDATION SUMMARY                           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Total checks: $check_count"
    echo -e "  Passed: $((check_count - failed_count))"
    echo -e "  Failed: $failed_count"
    echo ""

    if [[ $failed_count -eq 0 ]]; then
        echo -e "${GREEN}${CHECK_MARK} All Docker validation checks passed${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}${CROSS_MARK} Docker validation failed with $failed_count error(s):${NC}"
        for check in "${failed_checks[@]}"; do
            echo -e "${RED}  - $check${NC}"
        done
        echo ""

        # Provide comprehensive troubleshooting
        echo -e "${CYAN}Troubleshooting Steps:${NC}"
        echo -e "${CYAN}  1. Ensure Docker is installed: sudo apt-get install docker.io${NC}"
        echo -e "${CYAN}  2. Start Docker service: sudo systemctl start docker${NC}"
        echo -e "${CYAN}  3. Enable Docker on boot: sudo systemctl enable docker${NC}"
        echo -e "${CYAN}  4. Add user to docker group: sudo usermod -aG docker \$(whoami)${NC}"
        echo -e "${CYAN}  5. Re-login or run: newgrp docker${NC}"
        echo -e "${CYAN}  6. Test manually: docker run hello-world${NC}"
        echo ""

        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION (when sourced, this section doesn't run)
# =============================================================================
# If this script is executed directly (for testing), run all functions
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Running dependency module in test mode..."
    echo ""

    # Source os_detection.sh if available
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${SCRIPT_DIR}/os_detection.sh" ]]; then
        echo "Sourcing os_detection.sh..."
        source "${SCRIPT_DIR}/os_detection.sh"

        # Run OS detection
        detect_os || exit 1
        validate_os || exit 1
        get_package_manager || exit 1
        print_os_info
        echo ""
    else
        echo "WARNING: os_detection.sh not found, using defaults..."
        export PKG_MANAGER="apt"
    fi

    # Check dependencies
    if ! check_dependencies; then
        echo ""
        echo "Missing dependencies detected. Install them? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_dependencies || exit 3
        fi
    fi

    echo ""

    # Validate Docker
    validate_docker || exit 3

    echo ""
    echo -e "${GREEN}All tests passed successfully!${NC}"
    exit 0
fi
