#!/bin/bash
# ============================================================================
# VLESS Reality Deployment System
# Module: Network Parameters Generation
# Version: 1.0.0
# Task: TASK-2.1
# ============================================================================
#
# Purpose:
#   Automatically generate and validate network parameters (subnet, ports)
#   for VLESS Reality deployment. This module provides non-interactive
#   automatic generation as opposed to interactive_params.sh which collects
#   parameters interactively from the user.
#
# Functions:
#   1. generate_network_params()     - Main generator (subnet + port)
#   2. generate_docker_subnet()      - Auto-generate free Docker subnet
#   3. generate_vless_port()         - Auto-find available port
#   4. validate_subnet()             - Validate subnet format
#   5. validate_port()               - Validate port number
#   6. is_port_available()           - Check if port is free
#   7. is_subnet_available()         - Check if subnet is free
#   8. get_random_port()             - Generate random port in safe range
#   9. get_random_subnet()           - Generate random /16 subnet
#
# Usage:
#   source lib/network_params.sh
#   generate_network_params
#   # Sets: VLESS_PORT, DOCKER_SUBNET
#
# Environment Variables Set:
#   VLESS_PORT       - Port for VLESS server (e.g., 443, 8443, random)
#   DOCKER_SUBNET    - Docker bridge network subnet (e.g., 172.20.0.0/16)
#
# Exit Codes:
#   0 = Success
#   1 = Failure (no available resources found)
#
# Dependencies:
#   - docker (for network inspection)
#   - iproute2/net-tools (for port checking)
#
# Author: Claude Code Agent
# Date: 2025-10-02
# ============================================================================

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

# Exported variables (set by this module)
export VLESS_PORT=""
export DOCKER_SUBNET=""

# Default values (conditional to avoid conflicts with other modules)
[[ -z "${DEFAULT_VLESS_PORT:-}" ]] && readonly DEFAULT_VLESS_PORT=443
readonly FALLBACK_VLESS_PORT=8443
[[ -z "${DEFAULT_DOCKER_SUBNET:-}" ]] && readonly DEFAULT_DOCKER_SUBNET="172.20.0.0/16"

# Port range for random generation (avoid well-known ports below 1024)
readonly PORT_RANGE_MIN=10000
readonly PORT_RANGE_MAX=60000

# Private IP ranges for Docker subnets (RFC 1918)
readonly SUBNET_172_MIN=16
readonly SUBNET_172_MAX=31
readonly SUBNET_10_MIN=0
readonly SUBNET_10_MAX=255
readonly SUBNET_192_MIN=0
readonly SUBNET_192_MAX=255

# Colors for output (conditional to avoid conflicts when sourced by CLI)
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================

# Logging comes from lib/logger.sh — see the note there on why the output shape
# differs between a terminal and a captured stream.
# shellcheck source=lib/logger.sh
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

# ============================================================================
# Main Generation Function
# ============================================================================

generate_network_params() {
    log_info "Generating network parameters automatically..."
    echo ""

    # Generate VLESS port
    if ! generate_vless_port; then
        log_error "Failed to generate VLESS port"
        return 1
    fi

    # Generate Docker subnet
    if ! generate_docker_subnet; then
        log_error "Failed to generate Docker subnet"
        return 1
    fi

    # Display generated parameters
    echo ""
    log_success "Network parameters generated successfully"
    echo ""
    echo "  VLESS Port:    ${VLESS_PORT}"
    echo "  Docker Subnet: ${DOCKER_SUBNET}"
    echo ""

    return 0
}

# ============================================================================
# VLESS Port Generation
# ============================================================================

generate_vless_port() {
    log_info "Generating VLESS port..."

    # Try default port first (443)
    if is_port_available "$DEFAULT_VLESS_PORT"; then
        VLESS_PORT="$DEFAULT_VLESS_PORT"
        log_success "Using default port: ${VLESS_PORT}"
        return 0
    fi

    log_warning "Port ${DEFAULT_VLESS_PORT} is in use"

    # Try fallback port (8443)
    if is_port_available "$FALLBACK_VLESS_PORT"; then
        VLESS_PORT="$FALLBACK_VLESS_PORT"
        log_success "Using fallback port: ${VLESS_PORT}"
        return 0
    fi

    log_warning "Port ${FALLBACK_VLESS_PORT} is in use"

    # Try common alternative ports
    local common_ports=(443 8443 2053 2083 2087 2096)
    for port in "${common_ports[@]}"; do
        if is_port_available "$port"; then
            VLESS_PORT="$port"
            log_success "Using alternative port: ${VLESS_PORT}"
            return 0
        fi
    done

    # Generate random port
    log_info "Searching for random available port..."
    local max_attempts=100
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local random_port=$(get_random_port)
        if is_port_available "$random_port"; then
            VLESS_PORT="$random_port"
            log_success "Using random port: ${VLESS_PORT}"
            return 0
        fi
        ((attempt++))
    done

    log_error "No available ports found after ${max_attempts} attempts"
    return 1
}

# ============================================================================
# Docker Subnet Generation
# ============================================================================

generate_docker_subnet() {
    log_info "Generating Docker subnet..."

    # Try default subnet first (172.20.0.0/16)
    if is_subnet_available "$DEFAULT_DOCKER_SUBNET"; then
        DOCKER_SUBNET="$DEFAULT_DOCKER_SUBNET"
        log_success "Using default subnet: ${DOCKER_SUBNET}"
        return 0
    fi

    log_warning "Subnet ${DEFAULT_DOCKER_SUBNET} is in use"

    # Try common alternative subnets in 172.16-31.0.0/16 range
    log_info "Scanning for available subnet in 172.x.0.0/16 range..."
    for i in $(seq $SUBNET_172_MIN $SUBNET_172_MAX); do
        local subnet="172.${i}.0.0/16"
        if is_subnet_available "$subnet"; then
            DOCKER_SUBNET="$subnet"
            log_success "Found available subnet: ${DOCKER_SUBNET}"
            return 0
        fi
    done

    log_warning "No available subnets in 172.x.0.0/16 range"

    # Try 10.x.0.0/16 range (larger private IP space)
    log_info "Scanning for available subnet in 10.x.0.0/16 range..."
    for i in $(seq $SUBNET_10_MIN 10); do
        local subnet="10.${i}.0.0/16"
        if is_subnet_available "$subnet"; then
            DOCKER_SUBNET="$subnet"
            log_success "Found available subnet: ${DOCKER_SUBNET}"
            return 0
        fi
    done

    log_warning "No available subnets in 10.x.0.0/16 range (first 10 checked)"

    # Try 192.168.x.0/24 range (smaller subnets, less likely to conflict)
    log_info "Scanning for available subnet in 192.168.x.0/24 range..."
    for i in $(seq 100 200); do
        local subnet="192.168.${i}.0/24"
        if is_subnet_available "$subnet"; then
            DOCKER_SUBNET="$subnet"
            log_success "Found available subnet: ${DOCKER_SUBNET}"
            return 0
        fi
    done

    # Last resort: generate random subnet
    log_info "Generating random subnet..."
    local max_attempts=50
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local random_subnet=$(get_random_subnet)
        if is_subnet_available "$random_subnet"; then
            DOCKER_SUBNET="$random_subnet"
            log_success "Using random subnet: ${DOCKER_SUBNET}"
            return 0
        fi
        ((attempt++))
    done

    log_error "No available subnets found after extensive search"
    return 1
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_subnet() {
    local subnet="$1"

    # Validate format: x.x.x.x/y
    if ! [[ "$subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 1
    fi

    # Extract IP and CIDR
    local ip_part="${subnet%/*}"
    local cidr_part="${subnet#*/}"

    # Validate each octet
    IFS='.' read -ra octets <<< "$ip_part"
    if [ ${#octets[@]} -ne 4 ]; then
        return 1
    fi

    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
            return 1
        fi
    done

    # Validate CIDR (1-32)
    if [ "$cidr_part" -lt 1 ] || [ "$cidr_part" -gt 32 ]; then
        return 1
    fi

    return 0
}

validate_port() {
    local port="$1"

    # Check if numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Check range (1-65535)
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    return 0
}

# ============================================================================
# Availability Check Functions
# ============================================================================

is_port_available() {
    local port="$1"

    # Validate port number
    if ! validate_port "$port"; then
        return 1
    fi

    # Check with ss (modern tool)
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            return 1  # Port in use
        fi
    # Fallback to netstat
    elif command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
            return 1  # Port in use
        fi
    # Fallback to lsof
    elif command -v lsof &>/dev/null; then
        if lsof -i ":${port}" -sTCP:LISTEN -t &>/dev/null; then
            return 1  # Port in use
        fi
    else
        log_warning "No port checking tool available (ss, netstat, lsof)"
        # Assume available if no tools to check
        return 0
    fi

    return 0  # Port available
}

is_subnet_available() {
    local subnet="$1"

    # Validate subnet format
    if ! validate_subnet "$subnet"; then
        return 1
    fi

    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        log_warning "Docker not installed, cannot check subnet availability"
        return 0  # Assume available if Docker not present
    fi

    # Get existing Docker network subnets
    local existing_subnets
    existing_subnets=$(docker network ls --format '{{.ID}}' 2>/dev/null | \
        xargs -I {} docker network inspect {} --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | \
        grep -v '^$')

    # Check if subnet is already in use
    if echo "$existing_subnets" | grep -Fxq "$subnet"; then
        return 1  # Subnet in use
    fi

    # Check for subnet overlap (simplified check)
    # Extract network prefix (e.g., "172.20" from "172.20.0.0/16")
    local subnet_prefix
    subnet_prefix=$(echo "$subnet" | cut -d'.' -f1,2)

    if echo "$existing_subnets" | grep -q "^${subnet_prefix}\."; then
        # More thorough overlap check would require CIDR calculation
        # For now, warn but allow if not exact match
        log_warning "Potential subnet overlap with existing networks (${subnet_prefix}.x.x/y)"
    fi

    return 0  # Subnet available
}

# ============================================================================
# Random Generation Functions
# ============================================================================

get_random_port() {
    # Generate random port in safe range (10000-60000)
    local range=$((PORT_RANGE_MAX - PORT_RANGE_MIN))
    local random_offset=$((RANDOM % range))
    local port=$((PORT_RANGE_MIN + random_offset))
    echo "$port"
}

get_random_subnet() {
    # Generate random subnet in 172.16-31.0.0/16 range
    local second_octet=$((RANDOM % (SUBNET_172_MAX - SUBNET_172_MIN + 1) + SUBNET_172_MIN))
    echo "172.${second_octet}.0.0/16"
}

# ============================================================================
# Export Functions
# ============================================================================

# Export all functions for use by other scripts
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced
    export -f generate_network_params
    export -f generate_vless_port
    export -f generate_docker_subnet
    export -f validate_subnet
    export -f validate_port
    export -f is_port_available
    export -f is_subnet_available
    export -f get_random_port
    export -f get_random_subnet
    export -f log_info
    export -f log_success
    export -f log_warning
    export -f log_error
fi

# ============================================================================
# Main Execution (if run directly)
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly
    generate_network_params

    # Return exit code based on success
    if [[ -n "$VLESS_PORT" ]] && [[ -n "$DOCKER_SUBNET" ]]; then
        exit 0
    else
        exit 1
    fi
fi
