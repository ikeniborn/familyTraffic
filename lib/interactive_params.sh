#!/bin/bash
#
# Interactive Parameter Collection Module
# Part of VLESS+Reality VPN Deployment System
#
# Purpose: Interactively collect and validate installation parameters
# Parameters: Destination site, Docker subnet, Proxy configuration
# Usage: source this file from install.sh
#
# TASK-1.5: Interactive parameter collection (3h)
# v5.1: Removed VLESS port selection (hardcoded 8443 for nginx architecture)
#

# Only set strict mode if not already set (to avoid issues when sourced)
[[ ! -o pipefail ]] && set -euo pipefail || true

# =============================================================================
# GLOBAL VARIABLES (exported for use by other modules)
# =============================================================================

export REALITY_DEST=""
export REALITY_DEST_PORT=""
export VLESS_PORT=""
export DOCKER_SUBNET=""
export ENABLE_PROXY=""
export ENABLE_PUBLIC_PROXY=""  # v3.2: Public proxy access flag
export ENABLE_PROXY_TLS=""     # v3.4: TLS encryption for public proxy (true/false)
export PROXY_NOTLS_ENABLED=""  # v5.35: No-TLS proxy ports 1081/8119
export DOMAIN=""                # v3.3: Domain for Let's Encrypt certificate
export EMAIL=""                 # v3.3: Email for Let's Encrypt notifications
export DETECTED_DNS_PRIMARY=""    # v5.32: Primary DNS server (user-selected or auto-detected)
export DETECTED_DNS_SECONDARY=""  # v5.32: Secondary DNS server (user-selected or auto-detected)
export DETECTED_DNS_TERTIARY=""   # v5.32: Tertiary DNS server (user-selected or auto-detected)

# Color codes for output
# Only define if not already set (to avoid conflicts when sourced after install.sh)
[[ -z "${RED:-}" ]] && RED='\033[0;31m'
[[ -z "${GREEN:-}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE:-}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && NC='\033[0m' # No Color

# Default values (conditional to avoid conflicts with other modules)
# v5.30 nginx architecture: Xray listens on internal port 8443, nginx on external 443
[[ -z "${DEFAULT_VLESS_PORT:-}" ]] && readonly DEFAULT_VLESS_PORT=8443
[[ -z "${DEFAULT_DOCKER_SUBNET:-}" ]] && readonly DEFAULT_DOCKER_SUBNET="172.20.0.0/16"
readonly DEST_VALIDATION_TIMEOUT=10  # seconds

# Predefined destination sites (validated for Reality compatibility)
# Declare as associative array FIRST, then populate
declare -gA PREDEFINED_DESTINATIONS
PREDEFINED_DESTINATIONS=(
    ["1"]="www.google.com:443"
    ["2"]="www.microsoft.com:443"
    ["3"]="www.apple.com:443"
    ["4"]="www.cloudflare.com:443"
)

# =============================================================================
# FUNCTION: collect_parameters
# =============================================================================
# Description: Main function to collect all installation parameters interactively
# Called by: install.sh main()
# Sets: REALITY_DEST, REALITY_DEST_PORT, VLESS_PORT (hardcoded 8443), DOCKER_SUBNET
# Returns: 0 on success, 1 on failure or user cancellation
# v5.1: VLESS_PORT hardcoded to 8443 (nginx architecture requirement)
# =============================================================================
collect_parameters() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         INTERACTIVE PARAMETER COLLECTION                    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}This wizard will guide you through configuration.${NC}"
    echo -e "${CYAN}Press Ctrl+C at any time to cancel.${NC}"
    echo ""

    # v5.1: Hardcode VLESS port to 8443 (nginx architecture requirement)
    # nginx listens on external port 443 and forwards to Xray internal port 8443
    VLESS_PORT="$DEFAULT_VLESS_PORT"
    echo -e "${CYAN}Xray internal port: ${VLESS_PORT} (hardcoded for nginx architecture)${NC}"
    echo ""

    # Step 1: Select destination site
    select_destination_site || {
        echo -e "${RED}Failed to select destination site${NC}" >&2
        return 1
    }

    # Step 2: Select Docker subnet
    select_docker_subnet || {
        echo -e "${RED}Failed to select Docker subnet${NC}" >&2
        return 1
    }

    # Step 3: Enable public proxy support (v3.2)
    prompt_enable_public_proxy || {
        echo -e "${RED}Failed to configure proxy settings${NC}" >&2
        return 1
    }

    # Step 4: Prompt for domain and email (v3.4) - only if public proxy + TLS enabled
    if [[ "$ENABLE_PUBLIC_PROXY" == "true" ]] && [[ "$ENABLE_PROXY_TLS" == "true" ]]; then
        prompt_domain_email || {
            echo -e "${RED}Failed to configure TLS certificate settings${NC}" >&2
            return 1
        }
    fi


    prompt_ssh_source || return 1

    # Step 5: Confirm all parameters
    confirm_parameters || {
        echo -e "${YELLOW}Configuration cancelled by user${NC}"
        return 1
    }

    echo ""
    echo -e "${GREEN}✓ All parameters collected successfully${NC}"
    echo ""

    return 0
}

# =============================================================================
# FUNCTION: select_destination_site
# =============================================================================
# Description: Interactive menu to select Reality destination site
# Validates: TLS 1.3 support, HTTP/2, SNI extraction
# Sets: REALITY_DEST, REALITY_DEST_PORT
# Returns: 0 on success, 1 on failure
# =============================================================================
select_destination_site() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[1/2] Select Destination Site for Reality Masquerading${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Reality protocol 'borrows' the TLS handshake from a legitimate HTTPS site."
    echo "Your VPN traffic will be indistinguishable from normal traffic to this site."
    echo ""
    echo "Available options:"
    echo "  1) www.google.com:443      (Recommended - highly reliable)"
    echo "  2) www.microsoft.com:443   (Enterprise-friendly)"
    echo "  3) www.apple.com:443       (Good for regions where Google is blocked)"
    echo "  4) www.cloudflare.com:443  (CDN provider)"
    echo "  5) Custom site (advanced)  "
    echo ""

    local choice
    while true; do
        read -rp "Enter your choice [1-5] (default: 1): " choice
        choice=${choice:-1}  # Default to option 1

        # Validate input is a number
        if ! [[ "$choice" =~ ^[1-5]$ ]]; then
            echo -e "${RED}Invalid choice. Please enter 1, 2, 3, 4, or 5${NC}"
            continue
        fi

        # Handle custom destination
        if [[ "$choice" == "5" ]]; then
            echo ""
            echo -e "${YELLOW}Custom Destination Site${NC}"
            echo "Enter destination in format: domain.com:port"
            echo "Examples: www.example.com:443, example.org:443"
            echo ""

            local custom_dest
            read -rp "Custom destination: " custom_dest

            if [[ -z "$custom_dest" ]]; then
                echo -e "${RED}Destination cannot be empty${NC}"
                continue
            fi

            # Parse custom destination
            if [[ "$custom_dest" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]]; then
                local dest_host="${BASH_REMATCH[1]}"
                local dest_port="${BASH_REMATCH[2]}"

                echo ""
                echo -e "${CYAN}Validating custom destination: ${dest_host}:${dest_port}${NC}"

                if validate_destination "$dest_host" "$dest_port"; then
                    REALITY_DEST="$dest_host"
                    REALITY_DEST_PORT="$dest_port"
                    echo -e "${GREEN}✓ Custom destination validated successfully${NC}"

                    # v5.25: Automatic DNS detection
                    if detect_optimal_dns "$dest_host"; then
                        prompt_dns_selection
                    else
                        echo -e "${YELLOW}⚠ DNS auto-detection failed, using system DNS${NC}"
                        DETECTED_DNS=""
                    fi

                    return 0
                else
                    echo -e "${RED}✗ Validation failed for ${dest_host}:${dest_port}${NC}"
                    echo -e "${YELLOW}Please choose another destination${NC}"
                    echo ""
                    continue
                fi
            else
                echo -e "${RED}Invalid format. Use: domain.com:port${NC}"
                continue
            fi
        fi

        # Handle predefined destinations (1-4)
        local selected_dest="${PREDEFINED_DESTINATIONS[$choice]}"
        local dest_host="${selected_dest%%:*}"
        local dest_port="${selected_dest##*:}"

        echo ""
        echo -e "${CYAN}Selected: ${dest_host}:${dest_port}${NC}"
        echo -e "${CYAN}Validating destination (this may take up to ${DEST_VALIDATION_TIMEOUT} seconds)...${NC}"

        if validate_destination "$dest_host" "$dest_port"; then
            REALITY_DEST="$dest_host"
            REALITY_DEST_PORT="$dest_port"
            echo -e "${GREEN}✓ Destination validated successfully${NC}"

            # v5.25: Automatic DNS detection
            if detect_optimal_dns "$dest_host"; then
                prompt_dns_selection
            else
                echo -e "${YELLOW}⚠ DNS auto-detection failed, using system DNS${NC}"
                DETECTED_DNS=""
            fi

            echo ""
            return 0
        else
            echo -e "${YELLOW}Validation failed for ${dest_host}:${dest_port}${NC}"
            echo -e "${YELLOW}This destination may not be suitable. Try another option.${NC}"
            echo ""
            read -rp "Press Enter to select again..."
            continue
        fi
    done
}

# =============================================================================
# FUNCTION: validate_destination
# =============================================================================
# Description: Validate destination site for Reality compatibility
# Checks: TLS 1.3 support, reachability, SNI extraction
# Arguments: $1 - destination host, $2 - destination port
# Returns: 0 if valid, 1 if invalid
# =============================================================================
validate_destination() {
    local dest_host="$1"
    local dest_port="$2"

    # Check 1: DNS resolution
    echo -n "  [1/3] Checking DNS resolution... "
    # Use getent instead of host (getent is always available, host requires bind9-host package)
    if ! getent hosts "$dest_host" &>/dev/null; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}      Cannot resolve ${dest_host}${NC}"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    # Check 2: TLS connectivity
    echo -n "  [2/3] Checking TLS connectivity... "
    if ! timeout "$DEST_VALIDATION_TIMEOUT" openssl s_client -connect "${dest_host}:${dest_port}" \
         -servername "$dest_host" </dev/null &>/dev/null; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}      Cannot establish TLS connection to ${dest_host}:${dest_port}${NC}"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    # Check 3: TLS 1.3 support
    echo -n "  [3/3] Checking TLS 1.3 support... "
    local tls_version
    tls_version=$(timeout "$DEST_VALIDATION_TIMEOUT" openssl s_client -connect "${dest_host}:${dest_port}" \
                  -servername "$dest_host" -tls1_3 </dev/null 2>&1 | grep -oP 'Protocol\s*:\s*\K.*' | head -1)

    if [[ -z "$tls_version" ]] || ! echo "$tls_version" | grep -qi "TLSv1.3"; then
        echo -e "${YELLOW}WARN${NC}"
        echo -e "${YELLOW}      TLS 1.3 not confirmed, but may still work${NC}"
        # Don't fail on TLS 1.3 check - it's a soft requirement
    else
        echo -e "${GREEN}OK (${tls_version})${NC}"
    fi

    return 0
}

# =============================================================================
# FUNCTION: select_port - REMOVED in v5.1
# =============================================================================
# VLESS port is hardcoded to 8443 (Xray internal port; nginx listens on 443 via host network)
# Port selection removed in v5.1 (nginx architecture)
# =============================================================================

# =============================================================================
# FUNCTION: check_port_availability
# =============================================================================
# Description: Check if a port is available (not in use)
# Arguments: $1 - port number
# Returns: 0 if available, 1 if in use
# =============================================================================
check_port_availability() {
    local port="$1"

    # Method 1: Check with ss (socket statistics)
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            return 1  # Port in use
        fi
    # Method 2: Check with netstat (fallback)
    elif command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            return 1  # Port in use
        fi
    # Method 3: Check with lsof (fallback)
    elif command -v lsof &>/dev/null; then
        if lsof -i ":${port}" -sTCP:LISTEN &>/dev/null; then
            return 1  # Port in use
        fi
    else
        # No tools available - assume available (risky but better than failing)
        echo -e "${YELLOW}Warning: Cannot verify port availability (ss/netstat/lsof not found)${NC}" >&2
        return 0
    fi

    return 0  # Port available
}

# =============================================================================
# FUNCTION: suggest_alternative_ports - REMOVED in v5.1
# =============================================================================
# This function has been removed as VLESS port is now hardcoded to 8443
# =============================================================================

# =============================================================================
# FUNCTION: select_docker_subnet
# =============================================================================
# Description: Select Docker bridge network subnet with conflict detection
# Default: 172.20.0.0/16
# Scans: Existing Docker networks to avoid conflicts
# Sets: DOCKER_SUBNET
# Returns: 0 on success, 1 on failure
# =============================================================================
select_docker_subnet() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[2/2] Select Docker Network Subnet${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Docker bridge network will be created with an isolated subnet."
    echo "This ensures no conflicts with other VPN services."
    echo ""

    # Scan existing Docker networks
    echo -e "${CYAN}Scanning existing Docker networks...${NC}"
    local existing_subnets
    existing_subnets=$(scan_docker_networks)

    if [[ -n "$existing_subnets" ]]; then
        echo ""
        echo -e "${YELLOW}Existing Docker subnets:${NC}"
        echo "$existing_subnets" | while read -r line; do
            echo "  $line"
        done
        echo ""
    fi

    # Check if default subnet is available
    if ! echo "$existing_subnets" | grep -q "172.20.0.0/16"; then
        echo -e "${GREEN}✓ Default subnet ${DEFAULT_DOCKER_SUBNET} is available${NC}"
        echo ""

        local use_default
        read -rp "Use default subnet ${DEFAULT_DOCKER_SUBNET}? [Y/n]: " use_default
        use_default=${use_default:-Y}

        if [[ "$use_default" =~ ^[Yy]$ ]]; then
            DOCKER_SUBNET="$DEFAULT_DOCKER_SUBNET"
            echo -e "${GREEN}✓ Selected subnet: ${DOCKER_SUBNET}${NC}"
            echo ""
            return 0
        fi
    else
        echo -e "${YELLOW}⚠ Default subnet ${DEFAULT_DOCKER_SUBNET} is already in use${NC}"
        echo ""

        # Try to find a free subnet
        local free_subnet
        free_subnet=$(find_free_subnet "$existing_subnets")

        if [[ -n "$free_subnet" ]]; then
            echo -e "${GREEN}Found available subnet: ${free_subnet}${NC}"

            local use_free
            read -rp "Use this subnet? [Y/n]: " use_free
            use_free=${use_free:-Y}

            if [[ "$use_free" =~ ^[Yy]$ ]]; then
                DOCKER_SUBNET="$free_subnet"
                echo -e "${GREEN}✓ Selected subnet: ${DOCKER_SUBNET}${NC}"
                echo ""
                return 0
            fi
        fi
    fi

    # Manual subnet selection
    echo ""
    echo "Enter a custom subnet in CIDR notation (e.g., 172.21.0.0/16):"
    echo "Common private ranges: 172.16.0.0-172.31.0.0, 192.168.0.0-192.168.255.0"
    echo ""

    local custom_subnet
    while true; do
        read -rp "Subnet: " custom_subnet

        # Basic CIDR validation
        if [[ ! "$custom_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo -e "${RED}Invalid CIDR format. Example: 172.21.0.0/16${NC}"
            continue
        fi

        # Check if already in use
        if echo "$existing_subnets" | grep -q "$custom_subnet"; then
            echo -e "${YELLOW}This subnet is already in use by Docker. Choose another.${NC}"
            continue
        fi

        DOCKER_SUBNET="$custom_subnet"
        echo -e "${GREEN}✓ Selected subnet: ${DOCKER_SUBNET}${NC}"
        echo ""
        return 0
    done
}

# =============================================================================
# FUNCTION: scan_docker_networks
# =============================================================================
# Description: Scan existing Docker networks and extract subnets
# Returns: List of subnets (one per line), empty if Docker not available
# =============================================================================
scan_docker_networks() {
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        return 0
    fi

    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        return 0
    fi

    # Get all networks and their subnets
    docker network ls --format '{{.Name}}' 2>/dev/null | while read -r network_name; do
        local subnet
        subnet=$(docker network inspect "$network_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        if [[ -n "$subnet" ]]; then
            echo "${network_name}: ${subnet}"
        fi
    done
}

# =============================================================================
# FUNCTION: find_free_subnet
# =============================================================================
# Description: Find a free subnet in 172.x.0.0/16 range
# Arguments: $1 - list of existing subnets
# Returns: Free subnet in CIDR notation, empty if none found
# =============================================================================
find_free_subnet() {
    local existing_subnets="$1"

    # Try 172.20.0.0 through 172.30.0.0
    for i in {20..30}; do
        local candidate="172.${i}.0.0/16"
        if ! echo "$existing_subnets" | grep -q "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# FUNCTION: select_proxy_enable
# =============================================================================
# Description: Prompt user to enable SOCKS5/HTTP proxy support
# Sets: ENABLE_PROXY
# Returns: 0 on success, 1 on failure
# Related: TASK-11.1 (SOCKS5), TASK-11.2 (HTTP)
# =============================================================================
select_proxy_enable() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[4/4] Proxy Support Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Enable SOCKS5 and HTTP proxy support?"
    echo ""
    echo -e "${YELLOW}What are proxies?${NC}"
    echo "Proxies allow applications (VSCode, Docker, Git, terminal tools) to route"
    echo "traffic through your VPN connection without connecting to the VPN directly."
    echo ""
    echo -e "${YELLOW}How does it work?${NC}"
    echo "• Proxy servers bind to 127.0.0.1 (localhost only)"
    echo "• Accessible ONLY through the VPN tunnel (not exposed to Internet)"
    echo "• Each user gets unique password for authentication"
    echo ""
    echo -e "${YELLOW}What will be enabled:${NC}"
    echo "• SOCKS5 Proxy: Port 1080 (password auth, TCP only)"
    echo "• HTTP Proxy:   Port 8118 (password auth, HTTP/HTTPS)"
    echo ""
    echo -e "${YELLOW}Configuration files per user:${NC}"
    echo "• 3 VLESS configs (JSON, URI, QR code)"
    echo "• 5 proxy configs (SOCKS5, HTTP, VSCode, Docker, Bash)"
    echo ""

    local choice
    while true; do
        read -rp "Enable proxy support? [y/N] (default: N): " choice
        choice="${choice:-n}"  # Default to 'n'

        case "${choice,,}" in
            y|yes)
                ENABLE_PROXY="true"
                echo -e "${GREEN}✓ Proxy support ENABLED${NC}"
                echo "  Users will receive 8 config files (3 VLESS + 5 proxy)"
                break
                ;;
            n|no)
                ENABLE_PROXY="false"
                echo -e "${YELLOW}⊗ Proxy support DISABLED${NC}"
                echo "  Users will receive 3 VLESS config files only"
                break
                ;;
            *)
                echo -e "${RED}Invalid input. Please enter 'y' or 'n'${NC}"
                ;;
        esac
    done

    export ENABLE_PROXY
    echo ""
    return 0
}

# =============================================================================
# FUNCTION: confirm_parameters
# =============================================================================
# Description: Display all collected parameters and ask for confirmation
# Returns: 0 if confirmed, 1 if user wants to reconfigure
# =============================================================================
confirm_parameters() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║            CONFIGURATION SUMMARY                             ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Please review your configuration:${NC}"
    echo ""
    echo -e "  ${YELLOW}Destination Site:${NC}    ${REALITY_DEST}:${REALITY_DEST_PORT}"
    echo -e "  ${YELLOW}Xray Internal Port:${NC}  ${VLESS_PORT} (nginx forwards from 443)"
    echo -e "  ${YELLOW}Docker Subnet:${NC}       ${DOCKER_SUBNET}"
    echo -e "  ${YELLOW}SSH port 22 source:${NC}  ${SSH_ALLOW_FROM:-Any address} (existing rules preserved)"

    # v3.4: Display proxy mode with TLS status
    if [[ "$ENABLE_PUBLIC_PROXY" == "true" ]]; then
        if [[ "$ENABLE_PROXY_TLS" == "true" ]]; then
            echo -e "  ${YELLOW}Proxy Mode:${NC}          ${GREEN}Public (TLS encrypted)${NC}"
            echo -e "  ${YELLOW}⚠️  Ports 1080, 8118 exposed (socks5s://, https://)${NC}"
            # v3.3: Display domain and email if set
            if [[ -n "$DOMAIN" ]]; then
                echo -e "  ${YELLOW}TLS Domain:${NC}          ${DOMAIN}"
            fi
            if [[ -n "$EMAIL" ]]; then
                echo -e "  ${YELLOW}TLS Email:${NC}           ${EMAIL}"
            fi
        else
            echo -e "  ${YELLOW}Proxy Mode:${NC}          ${RED}Public (PLAINTEXT)${NC}"
            echo -e "  ${YELLOW}⚠️  Ports 1080, 8118 exposed (socks5://, http://)${NC}"
            echo -e "  ${RED}⚠️  WARNING: Credentials NOT encrypted!${NC}"
        fi
        if [[ "$PROXY_NOTLS_ENABLED" == "true" ]]; then
            echo -e "  ${YELLOW}No-TLS Ports:${NC}        ${RED}1081 (SOCKS5), 8119 (HTTP) — cleartext!${NC}"
        fi
    elif [[ "$ENABLE_PROXY" == "true" ]]; then
        echo -e "  ${YELLOW}Proxy Mode:${NC}          ${GREEN}Enabled (localhost only)${NC}"
    else
        echo -e "  ${YELLOW}Proxy Mode:${NC}          ${YELLOW}VLESS-ONLY MODE${NC}"
    fi


    # v5.32: Display DNS configuration (3 servers)
    if [[ -n "${DETECTED_DNS_PRIMARY}" ]]; then
        echo ""
        echo -e "  ${YELLOW}DNS Configuration:${NC}"
        echo -e "    ${GREEN}Primary:${NC}   ${DETECTED_DNS_PRIMARY}"
        echo -e "    ${GREEN}Secondary:${NC} ${DETECTED_DNS_SECONDARY}"
        echo -e "    ${GREEN}Tertiary:${NC}  ${DETECTED_DNS_TERTIARY}"
    fi
    echo ""

    local confirm
    while true; do
        read -rp "Is this configuration correct? [Y/n]: " confirm
        confirm=${confirm:-Y}

        case "$confirm" in
            [Yy]*)
                echo ""
                echo -e "${GREEN}✓ Configuration confirmed${NC}"
                return 0
                ;;
            [Nn]*)
                echo ""
                echo -e "${YELLOW}Configuration rejected. Please restart installation.${NC}"
                return 1
                ;;
            *)
                echo -e "${RED}Please answer Y or n${NC}"
                ;;
        esac
    done
}

# =============================================================================
# FUNCTION: prompt_domain_email
# =============================================================================
# Description: Prompt for domain and email for Let's Encrypt (v3.3)
# Required for: TLS certificate acquisition via certbot
# Sets: DOMAIN, EMAIL
# Returns: 0 on success, 1 on failure
# Related: TASK-1.7 (v3.3 TLS Enhancement)
# =============================================================================
prompt_domain_email() {
    echo ""
    echo "═════════════════════════════════════════════════════"
    echo "  TLS CERTIFICATE CONFIGURATION (v3.3)"
    echo "═════════════════════════════════════════════════════"
    echo ""
    echo "Public proxy mode requires TLS encryption via Let's Encrypt."
    echo ""
    echo -e "${YELLOW}Requirements:${NC}"
    echo "  ✓ A domain name pointing to this server"
    echo "  ✓ DNS A record configured (domain → server IP)"
    echo "  ✓ Port 80 accessible (temporary, for ACME challenge)"
    echo "  ✓ Valid email for renewal notifications"
    echo ""
    echo -e "${YELLOW}What happens:${NC}"
    echo "  1. DNS validation (domain must point to this server)"
    echo "  2. Let's Encrypt certificate acquisition (ACME HTTP-01)"
    echo "  3. Auto-renewal setup (twice daily checks)"
    echo "  4. TLS encryption enabled for SOCKS5/HTTP proxies"
    echo ""

    # Prompt for domain
    local server_ip
    server_ip=$(get_server_public_ip)

    echo -e "${CYAN}Server Public IP: ${server_ip}${NC}"
    echo ""

    local domain_input
    while true; do
        read -rp "Enter your domain name (e.g., vpn.example.com): " domain_input

        # Validate domain format
        if [[ -z "$domain_input" ]]; then
            echo -e "${RED}Domain cannot be empty${NC}"
            continue
        fi

        # Basic domain format validation (alphanumeric, dots, hyphens)
        if [[ ! "$domain_input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            echo -e "${RED}Invalid domain format${NC}"
            echo "Valid examples: vpn.example.com, server1.mydomain.org"
            continue
        fi

        # Validate DNS points to server
        echo ""
        echo -e "${CYAN}Validating DNS...${NC}"

        local dns_ip
        dns_ip=$(dig +short "$domain_input" A | head -1)

        if [[ -z "$dns_ip" ]]; then
            echo -e "${RED}✗ DNS resolution failed${NC}"
            echo "Domain '$domain_input' does not resolve to an IP address"
            echo ""
            echo "Fix steps:"
            echo "  1. Configure DNS A record: $domain_input → $server_ip"
            echo "  2. Wait for DNS propagation (1-48 hours)"
            echo "  3. Verify: dig +short $domain_input"
            echo ""
            read -rp "Try another domain? [Y/n]: " retry
            retry=${retry:-Y}
            [[ "$retry" =~ ^[Yy]$ ]] && continue || return 1
        fi

        if [[ "$dns_ip" != "$server_ip" ]]; then
            echo -e "${YELLOW}⚠ DNS mismatch${NC}"
            echo "Domain resolves to:  $dns_ip"
            echo "Expected:            $server_ip"
            echo ""
            echo "Options:"
            echo "  1. Update DNS A record to point to $server_ip"
            echo "  2. Continue anyway (certificate acquisition will fail)"
            echo "  3. Try another domain"
            echo ""
            read -rp "Continue with mismatched DNS? [y/N]: " continue_mismatch
            continue_mismatch=${continue_mismatch,,}

            if [[ "$continue_mismatch" == "y" || "$continue_mismatch" == "yes" ]]; then
                echo -e "${YELLOW}⚠ Proceeding with DNS mismatch (expect cert failure)${NC}"
                DOMAIN="$domain_input"
                break
            else
                continue
            fi
        fi

        # DNS validation successful
        echo -e "${GREEN}✓ DNS validated successfully${NC}"
        echo "  Domain: $domain_input"
        echo "  Resolves to: $dns_ip"
        echo ""
        DOMAIN="$domain_input"
        break
    done

    # Prompt for email
    echo ""
    local email_input
    while true; do
        read -rp "Enter email for Let's Encrypt notifications: " email_input

        # Validate email format
        if [[ -z "$email_input" ]]; then
            echo -e "${RED}Email cannot be empty${NC}"
            continue
        fi

        # Basic email validation (RFC 5322 simplified)
        if [[ ! "$email_input" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${RED}Invalid email format${NC}"
            echo "Valid examples: admin@example.com, user@domain.org"
            continue
        fi

        EMAIL="$email_input"
        echo -e "${GREEN}✓ Email validated${NC}"
        echo ""
        break
    done

    export DOMAIN
    export EMAIL

    echo -e "${GREEN}✓ Domain and email configured${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Email:  $EMAIL"
    echo ""

    return 0
}

# =============================================================================
# FUNCTION: get_server_public_ip
# =============================================================================
# Description: Get server's public IP address
# Returns: Public IP address as string, or "Unable to detect" on failure
# =============================================================================
get_server_public_ip() {
    local ip

    # Try multiple methods to get public IP
    ip=$(curl -s -4 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s -4 icanhazip.com 2>/dev/null) || \
    ip=$(curl -s -4 api.ipify.org 2>/dev/null) || \
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null) || \
    ip="Unable to detect"

    echo "$ip"
}


# =============================================================================
# FUNCTION: prompt_enable_public_proxy
# =============================================================================
# Description: Ask user if they want to enable public proxy access
# Sets: ENABLE_PUBLIC_PROXY (true/false)
# Returns: 0 always
# Related: v3.2 Public Proxy Support - TASK-3.1
# =============================================================================
prompt_enable_public_proxy() {
    echo ""
    echo "═════════════════════════════════════════════════════"
    echo "  PROXY CONFIGURATION (v5.30 - nginx Unified)"
    echo "═════════════════════════════════════════════════════"
    echo ""
    echo "VLESS Reality supports dual proxy modes:"
    echo ""
    echo "1. VLESS-ONLY MODE (default, safer):"
    echo "   - Only VLESS VPN available"
    echo "   - No SOCKS5/HTTP proxies"
    echo "   - Best for VPN-only use cases"
    echo ""
    echo "2. PUBLIC PROXY MODE (v5.30 - nginx TLS termination):"
    echo "   - TLS-encrypted SOCKS5 + HTTP proxies (socks5s://, https://)"
    echo "   - nginx handles TLS 1.3 encryption (unified architecture)"
    echo "   - No VPN client required (direct internet access)"
    echo "   - Requires: Domain name, Let's Encrypt certificate"
    echo ""
    echo "   Architecture: Client → nginx (TLS) → Xray (auth) → Internet"
    echo ""
    echo -e "${YELLOW}⚠️  WARNING: Public proxy exposes ports 1080 and 8118${NC}"
    echo -e "${YELLOW}⚠️  to the internet. Ensure your server can handle${NC}"
    echo -e "${YELLOW}⚠️  potential abuse and DDoS attempts.${NC}"
    echo ""
    echo "Security measures (auto-configured if YES):"
    echo "  ✓ nginx TLS 1.3 termination (unified architecture)"
    echo "  ✓ Let's Encrypt certificates with auto-renewal"
    echo "  ✓ Xray username + password authentication (mandatory)"
    echo "  ✓ Fail2ban (ban after 15 failed auth attempts)"
    echo "  ✓ UFW rules for authenticated proxy listeners"
    echo "  ✓ Proxy users can be added after installation; access stays locked until then"
    echo "  ✓ Optional UFW IP whitelisting (host firewall)"
    echo "  ✓ Xray routing rules (application-level IP filtering)"
    echo "  ✓ 32-character passwords (2^128 entropy)"
    echo ""
    echo -e "${CYAN}ℹ️  Additional features (configured after installation):${NC}"
    echo "  • Reverse Proxy (v4.3+): Access blocked sites via subdomain"
    echo "    Format: https://domain (NO port number!)"
    echo "    Setup: sudo familytraffic-proxy add"
    echo ""

    local response
    while true; do
        read -r -p "Enable public proxy access? [y/N]: " response
        response=${response,,}  # Convert to lowercase

        case "$response" in
            y|yes)
                echo ""
                echo -e "${YELLOW}⚠️  FINAL CONFIRMATION ⚠️${NC}"
                echo ""
                echo "You are about to enable PUBLIC INTERNET access to"
                echo "SOCKS5 (port 1080) and HTTP (port 8118) proxies."
                echo ""
                echo "This means ANYONE on the internet can ATTEMPT to"
                echo "connect to your proxy (authentication still required)."
                echo ""
                echo "Recommended for:"
                echo "  ✓ Private VPS with trusted users"
                echo "  ✓ Development/testing environments"
                echo "  ✓ Users who cannot install VPN clients"
                echo ""
                echo "NOT recommended for:"
                echo "  ✗ Shared hosting environments"
                echo "  ✗ Servers with weak DDoS protection"
                echo "  ✗ Compliance-sensitive deployments"
                echo ""

                local confirm
                read -r -p "Proceed with public proxy? [y/N]: " confirm
                confirm=${confirm,,}

                if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
                    ENABLE_PUBLIC_PROXY="true"
                    ENABLE_PROXY="true"  # Also enable proxy in general
                    echo ""
                    echo -e "${GREEN}✓ Public proxy mode enabled${NC}"
                    echo ""

                    # v3.4: Ask about TLS encryption
                    echo "═════════════════════════════════════════════════════"
                    echo "  TLS ENCRYPTION FOR PUBLIC PROXY"
                    echo "═════════════════════════════════════════════════════"
                    echo ""
                    echo "Choose proxy encryption mode:"
                    echo ""
                    echo "1. WITH TLS ENCRYPTION (recommended, requires domain):"
                    echo "   - Protocols: socks5s://, https://"
                    echo "   - Let's Encrypt certificates (free, auto-renewal)"
                    echo "   - Traffic encrypted end-to-end"
                    echo "   - Requires: domain name + DNS configuration"
                    echo ""
                    echo "2. WITHOUT TLS (plaintext, no domain required):"
                    echo "   - Protocols: socks5://, http://"
                    echo "   - No certificates needed"
                    echo "   - ⚠️  Credentials transmitted in plaintext"
                    echo "   - ⚠️  Suitable only for trusted networks"
                    echo ""

                    local tls_response
                    while true; do
                        read -r -p "Enable TLS encryption? [Y/n]: " tls_response
                        tls_response=${tls_response,,}  # Convert to lowercase
                        tls_response=${tls_response:-y}  # Default to 'y'

                        case "$tls_response" in
                            y|yes)
                                ENABLE_PROXY_TLS="true"
                                echo ""
                                echo -e "${GREEN}✓ TLS encryption enabled${NC}"
                                echo ""
                                echo "Requirements:"
                                echo "  - Domain name pointing to this server"
                                echo "  - Port 80 accessible (for ACME challenge)"
                                echo "  - Valid email for Let's Encrypt"
                                echo ""
                                echo "You will be prompted for domain and email next."
                                echo ""
                                break
                                ;;
                            n|no)
                                ENABLE_PROXY_TLS="false"
                                echo ""
                                echo -e "${YELLOW}⚠️  TLS encryption DISABLED${NC}"
                                echo ""
                                echo -e "${RED}WARNING: Proxy credentials will be transmitted in PLAINTEXT!${NC}"
                                echo ""
                                echo "This mode is suitable ONLY for:"
                                echo "  - Development/testing environments"
                                echo "  - Trusted private networks"
                                echo "  - Localhost-only access"
                                echo ""
                                echo "DO NOT use for production or untrusted networks!"
                                echo ""

                                local plaintext_confirm
                                read -r -p "Continue with plaintext proxy? [y/N]: " plaintext_confirm
                                plaintext_confirm=${plaintext_confirm,,}

                                if [[ "$plaintext_confirm" == "y" || "$plaintext_confirm" == "yes" ]]; then
                                    echo ""
                                    echo -e "${YELLOW}✓ Plaintext proxy mode confirmed${NC}"
                                    echo ""
                                    break
                                else
                                    echo ""
                                    echo "Plaintext mode canceled. Choose TLS encryption instead."
                                    echo ""
                                    continue
                                fi
                                ;;
                            *)
                                echo -e "${RED}Invalid response. Please enter 'y' or 'n'${NC}"
                                ;;
                        esac
                    done

                    # v5.35: Prompt for no-TLS proxy ports (only when TLS is enabled)
                    if [[ "$ENABLE_PROXY_TLS" == "true" ]]; then
                        echo ""
                        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                        echo -e "${CYAN}  ADDITIONAL: No-TLS Proxy Ports (v5.35)${NC}"
                        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                        echo ""
                        echo "  In addition to TLS-encrypted ports (1080/8118), you can enable"
                        echo "  plaintext proxy ports for clients that don't support TLS:"
                        echo ""
                        echo "    SOCKS5 (no TLS): port 1081"
                        echo "    HTTP   (no TLS): port 8119"
                        echo ""
                        echo -e "${YELLOW}  ⚠️  WARNING: Credentials transmitted in cleartext on these ports!${NC}"
                        echo -e "${YELLOW}  Use only in trusted networks or when TLS is not an option.${NC}"
                        echo ""

                        local notls_response
                        read -r -p "Enable no-TLS proxy ports? [y/N]: " notls_response
                        notls_response=${notls_response,,}

                        if [[ "$notls_response" == "y" || "$notls_response" == "yes" ]]; then
                            PROXY_NOTLS_ENABLED="true"
                            echo ""
                            echo -e "${GREEN}✓ No-TLS proxy ports enabled (1081/8119)${NC}"
                        else
                            PROXY_NOTLS_ENABLED="false"
                            echo ""
                            echo -e "${YELLOW}⊗ No-TLS proxy ports disabled${NC}"
                        fi
                    else
                        # Plaintext mode on 1080/8118 — additional no-TLS ports not needed
                        PROXY_NOTLS_ENABLED="false"
                    fi

                    echo ""
                    local step_num=1
                    echo "Next steps:"
                    echo "  $((step_num++)). Fail2ban will be installed"
                    echo "  $((step_num++)). UFW ports 1080, 8118 will be opened"
                    if [[ "$PROXY_NOTLS_ENABLED" == "true" ]]; then
                        echo "  $((step_num++)). UFW ports 1081, 8119 will be opened (no TLS)"
                    fi
                    echo "  $((step_num++)). All passwords will be 32 characters"
                    if [[ "$ENABLE_PROXY_TLS" == "true" ]]; then
                        echo "  $((step_num++)). Let's Encrypt certificate will be acquired"
                    fi
                    echo ""
                    break
                else
                    echo ""
                    echo "Public proxy canceled, falling back to VLESS-only mode"
                    ENABLE_PUBLIC_PROXY="false"
                    ENABLE_PROXY="false"
                    ENABLE_PROXY_TLS="false"
                    PROXY_NOTLS_ENABLED="false"
                    break
                fi
                ;;
            n|no|"")
                ENABLE_PUBLIC_PROXY="false"
                ENABLE_PROXY="false"
                ENABLE_PROXY_TLS="false"
                PROXY_NOTLS_ENABLED="false"
                echo ""
                echo -e "${GREEN}✓ VLESS-only mode (no public proxy)${NC}"
                echo ""
                break
                ;;
            *)
                echo -e "${RED}Invalid response. Please enter 'y' or 'n'${NC}"
                ;;
        esac
    done

    export ENABLE_PUBLIC_PROXY
    export ENABLE_PROXY
    export ENABLE_PROXY_TLS
    export PROXY_NOTLS_ENABLED
    return 0
}

# =============================================================================
# FUNCTION: test_dns_server
# =============================================================================
# Description: Test DNS resolution speed for a specific DNS server
# Arguments:
#   $1 - dns_server: DNS server IP address (e.g., "8.8.8.8")
#   $2 - test_domain: Domain to resolve (e.g., "www.google.com")
# Returns: Resolution time in milliseconds (or 9999 if failed)
# Example: test_dns_server "8.8.8.8" "www.google.com"
# v5.25: DNS auto-detection feature
# =============================================================================
test_dns_server() {
    local dns_server="$1"
    local test_domain="$2"
    local timeout_seconds=2

    # Check if dig is available
    if ! command -v dig &>/dev/null; then
        echo "9999"
        return 1
    fi

    # Test DNS resolution and extract query time
    local result
    result=$(dig +time="${timeout_seconds}" +tries=1 "@${dns_server}" "${test_domain}" 2>/dev/null | grep "Query time:" | awk '{print $4}')

    # Return 9999 if resolution failed or no result
    if [[ -z "$result" ]] || [[ "$result" == "0" ]]; then
        echo "9999"
        return 1
    fi

    echo "$result"
    return 0
}

# =============================================================================
# FUNCTION: detect_optimal_dns
# =============================================================================
# Description: Test multiple DNS servers and find the fastest one
# Arguments:
#   $1 - test_domain: Domain to test DNS resolution (typically REALITY_DEST)
# Side effects: Sets global array DNS_TEST_RESULTS with format "DNS_IP:TIME_MS:NAME"
# Returns: 0 on success (at least one DNS working), 1 if all failed
# v5.25: DNS auto-detection feature
# =============================================================================
detect_optimal_dns() {
    local test_domain="$1"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[AUTO] Detecting Optimal DNS Server for ${test_domain}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Check if dig is installed
    if ! command -v dig &>/dev/null; then
        echo -e "${YELLOW}⚠ 'dig' utility not found, installing dnsutils...${NC}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y dnsutils >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            sudo yum install -y bind-utils >/dev/null 2>&1
        else
            echo -e "${RED}Cannot install DNS utilities. Using system DNS.${NC}"
            DETECTED_DNS=""
            return 1
        fi
    fi

    # Get system DNS from /etc/resolv.conf
    local system_dns
    system_dns=$(grep -m 1 "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}')

    # DNS servers to test (v5.32: expanded to 12 servers)
    # Global DNS providers
    declare -A dns_servers
    dns_servers=(
        # Global DNS providers
        ["1.1.1.1"]="Cloudflare"
        ["8.8.8.8"]="Google"
        ["9.9.9.9"]="Quad9"
        ["208.67.222.222"]="OpenDNS"
        # Russian DNS providers - Yandex (3 modes)
        ["77.88.8.8"]="Yandex Basic"
        ["77.88.8.1"]="Yandex Basic (Secondary)"
        ["77.88.8.88"]="Yandex Safe"
        ["77.88.8.2"]="Yandex Safe (Secondary)"
        ["77.88.8.7"]="Yandex Family"
        ["77.88.8.3"]="Yandex Family (Secondary)"
    )

    # Add system DNS if available and not already in list
    if [[ -n "$system_dns" ]] && [[ ! "${dns_servers[$system_dns]+isset}" ]]; then
        dns_servers["$system_dns"]="System"
    fi

    echo "Testing DNS servers (this may take a few seconds)..."
    echo ""

    # Test all DNS servers
    declare -g -A DNS_TEST_RESULTS
    DNS_TEST_RESULTS=()

    for dns_ip in "${!dns_servers[@]}"; do
        local dns_name="${dns_servers[$dns_ip]}"
        echo -n "  Testing ${dns_name} (${dns_ip})... "

        local time_ms
        time_ms=$(test_dns_server "$dns_ip" "$test_domain")

        if [[ "$time_ms" == "9999" ]]; then
            echo -e "${RED}FAILED${NC}"
        else
            echo -e "${GREEN}${time_ms} ms${NC}"
            DNS_TEST_RESULTS["$dns_ip"]="${time_ms}:${dns_name}"
        fi
    done

    echo ""

    # Check if at least one DNS worked
    if [[ ${#DNS_TEST_RESULTS[@]} -eq 0 ]]; then
        echo -e "${RED}✗ All DNS servers failed. Using system DNS.${NC}"
        DETECTED_DNS=""
        return 1
    fi

    echo -e "${GREEN}✓ DNS testing completed${NC}"
    return 0
}

# =============================================================================
# FUNCTION: prompt_dns_selection
# =============================================================================
# Description: Display DNS test results and prompt user to select up to 3 DNS servers
# Side effects: Sets DETECTED_DNS_PRIMARY/SECONDARY/TERTIARY global variables
# Arguments: None (uses global DNS_TEST_RESULTS from detect_optimal_dns)
# Returns: 0 on success
# v5.32: Multiple DNS selection (up to 3 servers) with auto-select and fallback
# =============================================================================
prompt_dns_selection() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[SELECT] Choose DNS Servers (up to 3)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Sort DNS results by response time
    local sorted_dns=()
    while IFS= read -r line; do
        sorted_dns+=("$line")
    done < <(for dns_ip in "${!DNS_TEST_RESULTS[@]}"; do
        local result="${DNS_TEST_RESULTS[$dns_ip]}"
        local time_ms="${result%%:*}"
        local dns_name="${result##*:}"
        echo "${time_ms}:${dns_ip}:${dns_name}"
    done | sort -n)

    # Display top DNS servers
    echo "Available DNS servers (sorted by speed):"
    echo ""

    local idx=1
    declare -A menu_options
    declare -A menu_names
    declare -A menu_times
    for entry in "${sorted_dns[@]}"; do
        local time_ms="${entry%%:*}"
        local rest="${entry#*:}"
        local dns_ip="${rest%%:*}"
        local dns_name="${rest##*:}"

        echo "  ${idx}) ${dns_name} (${dns_ip}) - ${time_ms} ms"
        menu_options["$idx"]="$dns_ip"
        menu_names["$idx"]="$dns_name"
        menu_times["$idx"]="$time_ms"
        ((idx++))
    done

    echo "  ${idx}) Custom DNS server"
    echo ""

    # Get user selection (up to 3 DNS servers)
    local choice
    local max_option=$idx
    local custom_option=$idx
    local selected_ips=()
    local selected_names=()
    local selected_times=()

    while true; do
        echo -e "${YELLOW}Select up to 3 DNS servers:${NC}"
        echo "  - Comma-separated numbers (e.g., '1,2,3')"
        echo "  - Press ENTER to auto-select top 3 fastest"
        echo ""
        read -rp "Your choice [1-${max_option}]: " choice

        # Auto-select top 3 if empty
        if [[ -z "$choice" ]]; then
            echo ""
            echo -e "${CYAN}Auto-selecting top 3 fastest DNS servers...${NC}"
            # Iterate by numeric key 1..3 — associative array keys are unordered,
            # so "${!menu_options[@]}" would give arbitrary (non-sorted) results
            for i in 1 2 3; do
                [[ -n "${menu_options[$i]:-}" ]] || break
                selected_ips+=("${menu_options[$i]}")
                selected_names+=("${menu_names[$i]}")
                selected_times+=("${menu_times[$i]}")
            done
            break
        fi

        # Parse comma or space-separated input
        IFS=', ' read -ra dns_choices <<< "$choice"

        # Validate each choice
        local valid=true
        local temp_ips=()
        local temp_names=()
        local temp_times=()

        for c in "${dns_choices[@]}"; do
            # Trim whitespace
            c=$(echo "$c" | xargs)

            # Skip empty values
            [[ -z "$c" ]] && continue

            # Validate number format
            if ! [[ "$c" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid choice: '$c' (not a number)${NC}"
                valid=false
                break
            fi

            # Validate range
            if [[ "$c" -lt 1 ]] || [[ "$c" -gt "$max_option" ]]; then
                echo -e "${RED}Invalid choice: $c (must be 1-${max_option})${NC}"
                valid=false
                break
            fi

            # Handle custom DNS option
            if [[ "$c" == "$custom_option" ]]; then
                echo ""
                echo -e "${YELLOW}Custom DNS Server${NC}"
                echo "Enter DNS server IP address (e.g., 208.67.222.222 for OpenDNS)"
                echo ""

                local custom_dns
                read -rp "DNS IP: " custom_dns

                # Validate IP format
                if [[ "$custom_dns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    temp_ips+=("$custom_dns")
                    temp_names+=("Custom")
                    temp_times+=("N/A")
                else
                    echo -e "${RED}Invalid IP address format${NC}"
                    valid=false
                    break
                fi
            else
                # Check for duplicates
                local dns_ip="${menu_options[$c]}"
                local already_selected=false
                for existing_ip in "${temp_ips[@]}"; do
                    if [[ "$existing_ip" == "$dns_ip" ]]; then
                        echo -e "${YELLOW}⚠ DNS ${menu_names[$c]} (${dns_ip}) already selected, skipping duplicate${NC}"
                        already_selected=true
                        break
                    fi
                done

                if [[ "$already_selected" == false ]]; then
                    temp_ips+=("$dns_ip")
                    temp_names+=("${menu_names[$c]}")
                    temp_times+=("${menu_times[$c]}")
                fi
            fi

            # Limit to 3 DNS servers
            if [[ ${#temp_ips[@]} -ge 3 ]]; then
                break
            fi
        done

        # Check if validation passed
        if [[ "$valid" == false ]]; then
            continue
        fi

        # Check if at least one DNS selected
        if [[ ${#temp_ips[@]} -eq 0 ]]; then
            echo -e "${RED}Please select at least one DNS server${NC}"
            continue
        fi

        # Copy temp arrays to selected arrays
        selected_ips=("${temp_ips[@]}")
        selected_names=("${temp_names[@]}")
        selected_times=("${temp_times[@]}")

        break
    done

    # Fallback: auto-fill remaining slots with fastest DNS
    if [[ ${#selected_ips[@]} -lt 3 ]]; then
        echo ""
        echo -e "${CYAN}Auto-filling remaining slots with fastest DNS...${NC}"

        for i in "${!menu_options[@]}"; do
            # Skip if already selected
            local already_selected=false
            for existing_ip in "${selected_ips[@]}"; do
                if [[ "$existing_ip" == "${menu_options[$i]}" ]]; then
                    already_selected=true
                    break
                fi
            done

            if [[ "$already_selected" == false ]]; then
                selected_ips+=("${menu_options[$i]}")
                selected_names+=("${menu_names[$i]}")
                selected_times+=("${menu_times[$i]}")

                # Stop when we have 3
                if [[ ${#selected_ips[@]} -ge 3 ]]; then
                    break
                fi
            fi
        done
    fi

    # Assign to global variables
    DETECTED_DNS_PRIMARY="${selected_ips[0]:-1.1.1.1}"
    DETECTED_DNS_SECONDARY="${selected_ips[1]:-8.8.8.8}"
    DETECTED_DNS_TERTIARY="${selected_ips[2]:-77.88.8.8}"

    # Display selected DNS configuration
    echo ""
    echo -e "${GREEN}✓ Selected DNS servers:${NC}"
    echo -e "  ${CYAN}Primary:${NC}   ${selected_names[0]:-Cloudflare} (${DETECTED_DNS_PRIMARY}) - ${selected_times[0]:-default} ms"
    echo -e "  ${CYAN}Secondary:${NC} ${selected_names[1]:-Google} (${DETECTED_DNS_SECONDARY}) - ${selected_times[1]:-default} ms"
    echo -e "  ${CYAN}Tertiary:${NC}  ${selected_names[2]:-Yandex Basic} (${DETECTED_DNS_TERTIARY}) - ${selected_times[2]:-default} ms"

    export DETECTED_DNS_PRIMARY
    export DETECTED_DNS_SECONDARY
    export DETECTED_DNS_TERTIARY
    echo ""
    return 0
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Export all functions for use by install.sh
export -f collect_parameters
export -f select_destination_site
export -f validate_destination
export -f check_port_availability
export -f select_docker_subnet
export -f scan_docker_networks
export -f find_free_subnet
export -f confirm_parameters
export -f prompt_domain_email
export -f get_server_public_ip
export -f prompt_enable_public_proxy
export -f test_dns_server
export -f detect_optimal_dns
export -f prompt_dns_selection
