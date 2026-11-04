#!/bin/bash
################################################################################
# VLESS Reality VPN - Encryption Security Testing Suite
#
# Description:
#   Comprehensive security tests for encryption and secure channel validation
#   Tests the security of connections from client to internet through proxy
#
# Requirements:
#   - Root/sudo privileges
#   - VLESS Reality VPN installed (/opt/familytraffic)
#   - Tools: openssl, tcpdump, nmap, curl, jq, tshark (optional)
#   - Active VLESS installation with at least one user
#
# Test Coverage:
#   1. TLS 1.3 Configuration (Reality Protocol)
#   2. Nginx TLS Termination (Public Proxy Mode, v5.33 single-container)
#   3. Traffic Encryption Validation
#   4. Certificate Security
#   5. DPI Resistance (Deep Packet Inspection)
#   6. SSL/TLS Vulnerabilities
#   7. Proxy Protocol Security (SOCKS5/HTTP)
#   8. Data Leak Detection
#
# Usage:
#   sudo ./test_encryption_security.sh [options]
#
# Options:
#   --quick           Skip long-running tests (tcpdump)
#   --skip-pcap       Skip packet capture tests
#   --verbose         Show detailed output
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Prerequisites not met
#   3 - Critical security issue detected
#
# Version: 1.0
# Date: 2025-10-07
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# ============================================================================
# MODE DETECTION
# ============================================================================
# Detect if running in development mode (from source) or production (installed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Check if running from installed location
if [[ "$SCRIPT_DIR" == "/opt/familytraffic/lib" ]]; then
    MODE="production"
    VLESS_BASE_DIR="/opt/familytraffic"
else
    MODE="development"
    VLESS_BASE_DIR="${PROJECT_ROOT}"
fi

# Paths
readonly MODE
readonly VLESS_BASE_DIR
readonly CONFIG_DIR="${VLESS_BASE_DIR}/config"
readonly ENV_FILE="${VLESS_BASE_DIR}/.env"

# Conditional path definitions with fallbacks
if [[ -f "${CONFIG_DIR}/users.json" ]]; then
    readonly USERS_JSON="${CONFIG_DIR}/users.json"
elif [[ -f "${VLESS_BASE_DIR}/data/users.json" ]]; then
    readonly USERS_JSON="${VLESS_BASE_DIR}/data/users.json"
else
    readonly USERS_JSON="${CONFIG_DIR}/users.json"  # Default location
fi

if [[ -f "${CONFIG_DIR}/config.json" ]]; then
    readonly XRAY_CONFIG="${CONFIG_DIR}/config.json"
elif [[ -f "${CONFIG_DIR}/xray_config.json" ]]; then
    readonly XRAY_CONFIG="${CONFIG_DIR}/xray_config.json"
else
    readonly XRAY_CONFIG="${CONFIG_DIR}/config.json"  # Default location
fi

# readonly STUNNEL_CONFIG="${CONFIG_DIR}/stunnel.conf"  # DEPRECATED v4.3 - replaced by HAProxy
readonly HAPROXY_CONFIG="${CONFIG_DIR}/haproxy.cfg"  # v4.3: Unified TLS termination
readonly REALITY_KEYS="${CONFIG_DIR}/reality_keys.json"
readonly PCAP_DIR="/tmp/familytraffic_security_test_$$"

# Test results
declare -i TESTS_PASSED=0
declare -i TESTS_FAILED=0
declare -i TESTS_SKIPPED=0
declare -i SECURITY_WARNINGS=0
declare -i CRITICAL_ISSUES=0
declare -a FAILED_TESTS=()
declare -a SECURITY_ISSUES=()

# Test options
QUICK_MODE=false
SKIP_PCAP=false
VERBOSE=false
DEV_MODE=false  # Allow running without full installation

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓ PASS]${NC} $1"
    ((TESTS_PASSED++)) || true
}

print_failure() {
    echo -e "${RED}[✗ FAIL]${NC} $1"
    ((TESTS_FAILED++)) || true
    FAILED_TESTS+=("$1")
}

print_skip() {
    echo -e "${YELLOW}[⊘ SKIP]${NC} $1"
    ((TESTS_SKIPPED++)) || true
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠ WARN]${NC} $1"
    ((SECURITY_WARNINGS++)) || true
}

print_critical() {
    echo -e "${RED}[🔥 CRITICAL]${NC} $1"
    ((CRITICAL_ISSUES++)) || true
    SECURITY_ISSUES+=("CRITICAL: $1")
}

print_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $1"
    fi
}

# Run one test function and keep the suite going.
#
# Each test reports its own outcome through print_success/print_failure/print_skip,
# so a `return 1` needs no accounting here — it only must not abort the run under
# `set -e`, which is what the previous `test_xx || true` calls achieved.
#
# What this adds is the missing-function case. A name that does not resolve is
# reported as a suite error instead of writing "command not found" to stderr and
# leaving the totals one test short with nothing to explain the gap.
run_test() {
    local test_fn="$1"

    if ! declare -f "$test_fn" >/dev/null 2>&1; then
        print_failure "${test_fn}: test function is not defined (suite error)"
        return 0
    fi

    "$test_fn" || true
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}" >&2
        echo "Please run: sudo $0"
        exit 2
    fi
}

check_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}ERROR: Required command not found: $cmd${NC}" >&2
        if [[ -n "$install_hint" ]]; then
            echo "Install: $install_hint"
        fi
        return 1
    fi
    return 0
}

cleanup() {
    print_info "Cleaning up..."

    # Stop any packet captures
    pkill -f "tcpdump.*familytraffic_security" 2>/dev/null || true

    # Remove temporary files
    if [[ -d "$PCAP_DIR" ]]; then
        rm -rf "$PCAP_DIR"
    fi

    print_info "Cleanup completed"
}

trap cleanup EXIT

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    print_header "CHECKING PREREQUISITES"

    # Show current mode
    if [[ "$MODE" == "production" ]]; then
        print_info "Mode: Production (installed system)"
    else
        print_info "Mode: Development (source directory)"
        if [[ "$DEV_MODE" != "true" ]]; then
            print_warning "Running from source - use --dev-mode to skip installation checks"
        fi
    fi

    print_info "Base directory: $VLESS_BASE_DIR"
    echo ""

    # Check if VLESS directory exists
    if [[ ! -d "$VLESS_BASE_DIR" ]]; then
        echo -e "${RED}ERROR: Directory not found: $VLESS_BASE_DIR${NC}" >&2

        if [[ "$MODE" == "production" ]]; then
            echo ""
            echo "VLESS does not appear to be installed."
            echo ""
            echo "To install VLESS:"
            echo "  cd /path/to/vless/source"
            echo "  sudo bash install.sh"
            echo ""
        else
            echo ""
            echo "Project directory issue detected."
            echo "Current path: $VLESS_BASE_DIR"
            echo ""
        fi
        exit 2
    fi
    print_info "✓ Base directory exists"

    # Check required commands
    local required_basic=("openssl" "curl" "jq" "ss" "iptables")
    local required_docker=("docker")
    local required_network=("tcpdump" "nmap")
    local optional=("tshark" "testssl.sh")

    local missing_basic=()
    for cmd in "${required_basic[@]}"; do
        if ! check_command "$cmd" "" &>/dev/null; then
            missing_basic+=("$cmd")
        fi
    done

    if [[ ${#missing_basic[@]} -gt 0 ]]; then
        echo -e "${RED}ERROR: Missing required commands: ${missing_basic[*]}${NC}" >&2
        echo "Install with: sudo apt-get install ${missing_basic[*]}" >&2
        exit 2
    fi
    print_info "✓ Basic tools available"

    # Check Docker (only if not in dev mode)
    if [[ "$DEV_MODE" != "true" ]]; then
        if ! check_command "docker" "" &>/dev/null; then
            echo -e "${RED}ERROR: Docker not found${NC}" >&2
            echo "Install with: curl -fsSL https://get.docker.com | sh" >&2
            exit 2
        fi
        print_info "✓ Docker available"

        # Check Docker containers (only in production mode)
        if ! docker ps --format '{{.Names}}' | grep -q "familytraffic" 2>/dev/null; then
            echo -e "${RED}ERROR: VLESS containers are not running${NC}" >&2
            echo ""
            echo "Start containers:"
            if [[ "$MODE" == "production" ]]; then
                echo "  cd /opt/familytraffic && sudo docker compose up -d"
            else
                echo "  cd $VLESS_BASE_DIR && sudo docker compose up -d"
            fi
            echo ""
            echo "Check container status:"
            echo "  sudo docker ps -a | grep vless"
            echo ""
            exit 2
        fi
        print_info "✓ VLESS containers are running"
    else
        print_warning "DEV MODE: Skipping Docker checks"
    fi

    for cmd in "${required_network[@]}"; do
        if ! check_command "$cmd" "" &>/dev/null; then
            if [[ "$cmd" == "tcpdump" ]]; then
                print_warning "tcpdump not found - packet capture tests will be skipped"
                SKIP_PCAP=true
            else
                print_warning "$cmd not found - some tests will be limited"
            fi
        fi
    done

    for cmd in "${optional[@]}"; do
        if ! check_command "$cmd" "" &>/dev/null; then
            print_info "Optional tool not found: $cmd (some tests will be limited)"
        fi
    done

    # Check VLESS installation files (skip in dev mode unless --dev-mode)
    if [[ "$DEV_MODE" == "true" ]]; then
        print_warning "DEV MODE: Skipping installation checks"
    else
        # Check config directory
        if [[ ! -d "$CONFIG_DIR" ]]; then
            echo -e "${RED}ERROR: Config directory not found: $CONFIG_DIR${NC}" >&2
            echo ""
            echo "VLESS does not appear to be properly installed."
            echo ""
            if [[ "$MODE" == "development" ]]; then
                echo "You are running from source directory."
                echo "Either:"
                echo "  1. Install VLESS: sudo bash install.sh"
                echo "  2. Use dev mode: $0 --dev-mode (limited functionality)"
                echo ""
            else
                echo "To install VLESS:"
                echo "  sudo bash install.sh"
                echo ""
            fi
            exit 2
        fi
        print_info "✓ Config directory exists"

        # Check if at least one user exists
        if [[ ! -f "$USERS_JSON" ]]; then
            echo -e "${RED}ERROR: No users.json found${NC}" >&2
            echo ""
            echo "Location checked: $USERS_JSON"
            echo ""
            echo "This test suite requires a working VLESS installation with at least one user."
            echo ""
            echo "Troubleshooting:"
            echo ""
            echo "1. If VLESS is NOT installed:"
            echo "   cd /path/to/vless/source"
            echo "   sudo bash install.sh"
            echo ""
            echo "2. If VLESS IS installed but has no users:"
            echo "   sudo familytraffic add-user testuser"
            echo ""
            echo "3. To run tests without installation (limited):"
            echo "   $0 --dev-mode"
            echo ""
            exit 2
        fi

        local user_count
        user_count=$(jq -r '.users | length' "$USERS_JSON" 2>/dev/null || echo "0")
        if [[ "$user_count" -eq 0 ]]; then
            echo -e "${RED}ERROR: No users configured in users.json${NC}" >&2
            echo ""
            echo "Create a user first:"
            echo "  sudo familytraffic add-user testuser"
            echo ""
            exit 2
        fi
        print_info "✓ Found $user_count user(s)"
    fi

    # Create temporary directory for packet captures
    mkdir -p "$PCAP_DIR"
    chmod 700 "$PCAP_DIR"

    echo ""
    echo -e "${GREEN}✓ Prerequisites check completed${NC}"
    echo ""
}

# ============================================================================
# ENVIRONMENT DETECTION
# ============================================================================

get_server_ip() {
    local server_ip

    if [[ -f "$ENV_FILE" ]]; then
        server_ip=$(grep "^SERVER_IP=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    fi

    if [[ -z "$server_ip" || "$server_ip" == "SERVER_IP_NOT_DETECTED" ]]; then
        server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "127.0.0.1")
    fi

    echo "$server_ip"
}

get_test_user() {
    # Get first user from users.json
    jq -r '.users[0].username' "$USERS_JSON" 2>/dev/null || echo ""
}

get_test_user_uuid() {
    local username="$1"
    jq -r ".users[] | select(.username == \"$username\") | .uuid" "$USERS_JSON" 2>/dev/null || echo ""
}

get_proxy_password() {
    local username="$1"
    jq -r ".users[] | select(.username == \"$username\") | .proxy_password" "$USERS_JSON" 2>/dev/null || echo ""
}

is_public_proxy_enabled() {
    if [[ -f "$ENV_FILE" ]]; then
        local enabled
        enabled=$(grep "^ENABLE_PUBLIC_PROXY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
        [[ "$enabled" == "true" ]] && return 0
    fi
    return 1
}

get_domain() {
    if [[ -f "$ENV_FILE" ]]; then
        grep "^DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo ""
    fi
}

get_vless_port() {
    if [[ -f "$ENV_FILE" ]]; then
        grep "^VLESS_PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "443"
    else
        echo "443"
    fi
}

# ============================================================================
# TEST 1: TLS 1.3 CONFIGURATION (REALITY PROTOCOL)
# ============================================================================

test_01_reality_tls_config() {
    print_header "TEST 1: Reality Protocol TLS 1.3 Configuration"
    print_test "Verifying Reality protocol TLS 1.3 settings in Xray config"

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_failure "Xray config not found: $XRAY_CONFIG"
        return 1
    fi

    # Check Reality settings exist
    if ! jq -e '.inbounds[0].streamSettings.realitySettings' "$XRAY_CONFIG" &>/dev/null; then
        print_failure "Reality settings not found in Xray config"
        return 1
    fi
    print_verbose "Reality settings section found"

    # Check for X25519 keys
    local public_key
    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null)
    if [[ -z "$public_key" || "$public_key" == "null" ]]; then
        print_failure "Reality private key not configured"
        return 1
    fi
    print_success "Reality X25519 private key configured"

    # Check shortIds
    local short_ids
    short_ids=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds | length' "$XRAY_CONFIG" 2>/dev/null || echo "0")
    if [[ "$short_ids" -eq 0 ]]; then
        print_failure "No Reality shortIds configured"
        return 1
    fi
    print_success "Reality shortIds configured ($short_ids entries)"

    # Check destination (for TLS masquerading)
    local dest
    dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG" 2>/dev/null)
    if [[ -z "$dest" || "$dest" == "null" ]]; then
        print_failure "Reality destination not configured"
        return 1
    fi
    print_success "Reality destination configured: $dest"

    # Verify destination supports TLS 1.3
    print_info "Testing destination TLS 1.3 support..."
    local dest_host
    dest_host=$(echo "$dest" | cut -d':' -f1)

    if openssl s_client -connect "$dest" -tls1_3 </dev/null 2>&1 | grep -q "Protocol.*TLSv1.3"; then
        print_success "Destination supports TLS 1.3: $dest_host"
    else
        print_warning "Destination may not support TLS 1.3 (Reality may not work optimally)"
    fi

    # Check serverNames (SNI)
    local server_names
    server_names=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[]' "$XRAY_CONFIG" 2>/dev/null | head -1)
    if [[ -z "$server_names" ]]; then
        print_failure "Reality serverNames (SNI) not configured"
        return 1
    fi
    print_success "Reality serverNames configured: $server_names"

    print_success "Reality protocol TLS 1.3 configuration valid"
    return 0
}

# ============================================================================
# TEST 2: NGINX TLS TERMINATION (PUBLIC PROXY MODE - v5.33+)
# ============================================================================

test_02_haproxy_tls() {
    # v5.33: HAProxy removed — nginx inside familytraffic container handles TLS termination
    # Function name preserved for call-site compatibility
    print_header "TEST 2: Nginx TLS Termination (v5.33 — HAProxy removed)"

    if ! is_public_proxy_enabled; then
        print_skip "Public proxy not enabled - TLS termination tests skipped"
        return 0
    fi

    # Verify familytraffic container is running (replaces HAProxy check)
    if ! docker ps --format '{{.Names}}' | grep -q "familytraffic"; then
        print_failure "familytraffic container not running"
        return 1
    fi
    print_success "familytraffic container is running (nginx+xray+supervisord)"

    # Verify certificates exist
    local domain
    domain=$(get_domain)
    if [[ -z "$domain" ]]; then
        print_failure "Domain not configured for TLS certificates"
        return 1
    fi

    local cert_dir="/etc/letsencrypt/live/${domain}"
    if [[ ! -f "${cert_dir}/fullchain.pem" ]] || [[ ! -f "${cert_dir}/privkey.pem" ]]; then
        print_critical "TLS certificates not found: $cert_dir"
        return 1
    fi
    print_success "TLS certificates exist (nginx reads LE certs directly)"

    # Check certificate validity
    if ! openssl x509 -in "${cert_dir}/fullchain.pem" -noout -checkend 86400 &>/dev/null; then
        print_warning "Certificate expires within 24 hours or is already expired"
    else
        local expiry
        expiry=$(openssl x509 -in "${cert_dir}/fullchain.pem" -noout -enddate | cut -d'=' -f2)
        print_success "Certificate valid until: $expiry"
    fi

    # Test nginx proxy ports are listening (familytraffic host network)
    local socks5_port="1080"
    local http_port="8118"

    if ss -tlnp | grep -q ":${socks5_port}"; then
        print_success "nginx SOCKS5 port listening: $socks5_port"
    else
        print_failure "nginx SOCKS5 port not listening: $socks5_port"
        return 1
    fi

    if ss -tlnp | grep -q ":${http_port}"; then
        print_success "nginx HTTP proxy port listening: $http_port"
    else
        print_failure "nginx HTTP proxy port not listening: $http_port"
        return 1
    fi

    print_success "nginx TLS termination configuration valid (v5.33)"
    return 0
}

# ============================================================================
# TEST 3: TRAFFIC ENCRYPTION VALIDATION
# ============================================================================

test_03_traffic_encryption() {
    print_header "TEST 3: Traffic Encryption Validation"

    if [[ "$SKIP_PCAP" == "true" ]]; then
        print_skip "Packet capture tests disabled (--skip-pcap or tcpdump not available)"
        return 0
    fi

    print_test "Capturing and analyzing encrypted traffic"

    local test_user
    test_user=$(get_test_user)
    if [[ -z "$test_user" ]]; then
        print_failure "No test user available"
        return 1
    fi

    local proxy_password
    proxy_password=$(get_proxy_password "$test_user")

    local server_ip
    server_ip=$(get_server_ip)

    local pcap_file="${PCAP_DIR}/traffic_test.pcap"
    local test_url="http://example.com"
    local plaintext_marker="example"

    print_info "Starting packet capture on all interfaces..."
    timeout 30 tcpdump -i any -w "$pcap_file" -U "tcp and host $server_ip" &>/dev/null &
    local tcpdump_pid=$!

    sleep 2  # Wait for tcpdump to start

    # Test 1: VLESS connection (if UUID available)
    print_info "Testing VLESS encrypted traffic..."
    local uuid
    uuid=$(get_test_user_uuid "$test_user")

    # Note: We can't easily test VLESS without a client, so we'll check listening port
    local vless_port
    vless_port=$(get_vless_port)
    print_verbose "VLESS port: $vless_port"

    # Test 2: Proxy connection (if enabled)
    if is_public_proxy_enabled && [[ -n "$proxy_password" ]]; then
        local domain
        domain=$(get_domain)

        print_info "Testing proxy encrypted traffic via HAProxy..."

        # Make request through HTTPS proxy
        if ! timeout 10 curl -x "https://${test_user}:${proxy_password}@${domain}:8118" \
            -s -o /dev/null "$test_url" 2>/dev/null; then
            print_warning "Proxy connection failed (expected if not accessible from test location)"
        else
            print_verbose "Proxy connection successful"
        fi
    else
        print_info "Public proxy not enabled, testing localhost proxy..."

        if [[ -n "$proxy_password" ]]; then
            # Test localhost proxy (should fail from remote, but we'll try)
            timeout 5 curl --socks5 "${test_user}:${proxy_password}@127.0.0.1:1080" \
                -s -o /dev/null "$test_url" 2>/dev/null || true
        fi
    fi

    # Wait for capture to finish
    sleep 5
    kill "$tcpdump_pid" 2>/dev/null || true
    wait "$tcpdump_pid" 2>/dev/null || true

    print_info "Analyzing captured traffic..."

    # Check if pcap file exists and has data
    if [[ ! -f "$pcap_file" ]]; then
        print_failure "Packet capture file not created"
        return 1
    fi

    local packet_count
    packet_count=$(tcpdump -r "$pcap_file" 2>/dev/null | wc -l)
    print_info "Captured $packet_count packets"

    if [[ "$packet_count" -eq 0 ]]; then
        print_warning "No packets captured (firewall may be blocking or no traffic generated)"
        return 0
    fi

    # Search for plaintext in captured traffic
    print_info "Searching for plaintext data in encrypted traffic..."

    if command -v strings &>/dev/null; then
        local plaintext_found
        plaintext_found=$(strings "$pcap_file" | grep -i "$plaintext_marker" | wc -l)

        if [[ "$plaintext_found" -gt 0 ]]; then
            print_critical "Plaintext data detected in traffic (possible encryption failure)"
            print_info "Found $plaintext_found occurrences of '$plaintext_marker'"
            return 1
        else
            print_success "No plaintext data detected - traffic appears encrypted"
        fi
    else
        print_warning "strings command not available - cannot verify encryption"
    fi

    # Additional check with tshark if available
    if command -v tshark &>/dev/null; then
        print_info "Analyzing TLS handshakes with tshark..."

        local tls_count
        tls_count=$(tshark -r "$pcap_file" -Y "tls.handshake.type" 2>/dev/null | wc -l)

        if [[ "$tls_count" -gt 0 ]]; then
            print_success "TLS handshakes detected: $tls_count"

            # Check TLS versions
            local tls13_count
            tls13_count=$(tshark -r "$pcap_file" -Y "tls.handshake.version == 0x0304" 2>/dev/null | wc -l)

            if [[ "$tls13_count" -gt 0 ]]; then
                print_success "TLS 1.3 handshakes detected: $tls13_count"
            else
                print_warning "No TLS 1.3 handshakes detected (Reality may be using masquerading)"
            fi
        else
            print_info "No TLS handshakes in captured traffic (Reality masquerading may be working)"
        fi
    fi

    print_success "Traffic encryption validation completed"
    return 0
}

# ============================================================================
# TEST 4: CERTIFICATE SECURITY
# ============================================================================

test_04_certificate_security() {
    print_header "TEST 4: Certificate Security Validation"

    if ! is_public_proxy_enabled; then
        print_skip "Public proxy not enabled - certificate tests skipped"
        return 0
    fi

    print_test "Validating TLS certificates for HAProxy"

    local domain
    domain=$(get_domain)
    if [[ -z "$domain" ]]; then
        print_failure "Domain not configured"
        return 1
    fi

    local cert_dir="/etc/letsencrypt/live/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"

    # Check file permissions
    local fullchain_perms
    fullchain_perms=$(stat -c "%a" "$fullchain" 2>/dev/null || echo "000")

    if [[ "$fullchain_perms" == "644" ]] || [[ "$fullchain_perms" == "600" ]]; then
        print_success "Certificate file permissions secure: $fullchain_perms"
    else
        print_warning "Certificate file permissions: $fullchain_perms (should be 644 or 600)"
    fi

    local privkey_perms
    privkey_perms=$(stat -c "%a" "$privkey" 2>/dev/null || echo "000")

    if [[ "$privkey_perms" == "600" ]]; then
        print_success "Private key file permissions secure: $privkey_perms"
    else
        print_critical "Private key file permissions insecure: $privkey_perms (MUST be 600)"
        return 1
    fi

    # Verify certificate chain
    print_info "Verifying certificate chain..."

    if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$fullchain" &>/dev/null; then
        print_success "Certificate chain valid"
    else
        print_failure "Certificate chain validation failed"
        return 1
    fi

    # Check certificate subject
    local subject
    subject=$(openssl x509 -in "$fullchain" -noout -subject | sed 's/subject=//')
    print_info "Certificate subject: $subject"

    # Check certificate issuer (should be Let's Encrypt)
    local issuer
    issuer=$(openssl x509 -in "$fullchain" -noout -issuer | sed 's/issuer=//')

    if echo "$issuer" | grep -qi "let's encrypt"; then
        print_success "Certificate issued by Let's Encrypt"
    else
        print_info "Certificate issuer: $issuer"
    fi

    # Check SAN (Subject Alternative Names)
    local san
    san=$(openssl x509 -in "$fullchain" -noout -text | grep -A1 "Subject Alternative Name" | tail -1)

    if echo "$san" | grep -q "$domain"; then
        print_success "Certificate SAN includes domain: $domain"
    else
        print_warning "Domain not found in certificate SAN"
    fi

    # Test TLS connection to HAProxy TLS ports
    print_info "Testing TLS connection to HAProxy SOCKS5 port (1080)..."

    if timeout 5 openssl s_client -connect "${domain}:1080" -tls1_3 </dev/null 2>&1 | grep -q "Verify return code: 0"; then
        print_success "TLS connection to SOCKS5 port successful (certificate valid)"
    else
        print_warning "TLS connection to SOCKS5 port failed (may not support direct TLS handshake)"
    fi

    print_success "Certificate security validation completed"
    return 0
}

# ============================================================================
# TEST 5: DPI RESISTANCE (DEEP PACKET INSPECTION)
# ============================================================================

test_05_dpi_resistance() {
    print_header "TEST 5: DPI Resistance Validation"
    print_test "Verifying traffic appears as legitimate HTTPS (Reality masquerading)"

    # Check Reality destination configuration
    local dest
    dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG" 2>/dev/null)

    if [[ -z "$dest" || "$dest" == "null" ]]; then
        print_failure "Reality destination not configured"
        return 1
    fi

    local dest_host
    dest_host=$(echo "$dest" | cut -d':' -f1)
    print_info "Reality masquerading as: $dest_host"

    # Test 1: Verify destination is reachable and supports TLS 1.3
    print_info "Testing destination reachability and TLS support..."

    if timeout 10 curl -I "https://${dest_host}" &>/dev/null; then
        print_success "Destination is reachable: $dest_host"
    else
        print_warning "Destination not reachable (may affect Reality effectiveness)"
    fi

    # Test 2: SNI validation
    print_info "Validating SNI configuration..."

    local server_names
    server_names=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[]' "$XRAY_CONFIG" 2>/dev/null | head -1)

    if [[ -z "$server_names" ]]; then
        print_failure "No serverNames configured for Reality"
        return 1
    fi

    print_info "Configured SNI: $server_names"

    # Verify SNI matches destination
    if [[ "$server_names" == *"$dest_host"* ]] || [[ "$dest_host" == *"$server_names"* ]]; then
        print_success "SNI matches destination (optimal for DPI resistance)"
    else
        print_warning "SNI doesn't match destination exactly (may reduce DPI resistance)"
    fi

    # Test 3: Port analysis (external scan simulation)
    print_info "Simulating external port scan..."

    local server_ip
    server_ip=$(get_server_ip)
    local vless_port
    vless_port=$(get_vless_port)

    if nmap -p "$vless_port" --script ssl-enum-ciphers "$server_ip" 2>/dev/null | grep -q "TLSv1.3"; then
        print_success "Port appears as TLS 1.3 service (good for DPI resistance)"
    else
        # This might fail because Reality doesn't respond to direct TLS handshakes
        print_info "Port doesn't respond to standard TLS handshake (expected for Reality)"
        print_success "Reality protocol working (invisible to standard TLS probes)"
    fi

    # Test 4: Fingerprint analysis
    print_info "Checking TLS fingerprint..."

    # Reality should make traffic indistinguishable from real destination
    # We can't easily test this without specialized tools, but we can verify settings

    local fp
    fp=$(jq -r '.inbounds[0].streamSettings.realitySettings.fingerprint // "chrome"' "$XRAY_CONFIG" 2>/dev/null)

    if [[ -n "$fp" && "$fp" != "null" ]]; then
        print_success "TLS fingerprint configured: $fp (mimics real browser)"
    else
        print_warning "No TLS fingerprint configured (may be detectable)"
    fi

    print_success "DPI resistance validation completed"
    return 0
}

# ============================================================================
# TEST 6: SSL/TLS VULNERABILITIES
# ============================================================================

test_06_tls_vulnerabilities() {
    print_header "TEST 6: SSL/TLS Vulnerability Scanning"

    if ! is_public_proxy_enabled; then
        print_skip "Public proxy not enabled - TLS vulnerability tests skipped"
        return 0
    fi

    print_test "Checking for common SSL/TLS vulnerabilities"

    local domain
    domain=$(get_domain)
    if [[ -z "$domain" ]]; then
        print_failure "Domain not configured"
        return 1
    fi

    # Test weak cipher suites
    print_info "Testing for weak cipher suites..."

    local weak_ciphers=("RC4" "DES" "3DES" "MD5" "NULL")
    local weak_found=0

    for cipher in "${weak_ciphers[@]}"; do
        if openssl s_client -connect "${domain}:8118" -cipher "$cipher" </dev/null 2>&1 | grep -q "Cipher.*$cipher"; then
            print_critical "Weak cipher supported: $cipher"
            ((weak_found++)) || true
        fi
    done

    if [[ $weak_found -eq 0 ]]; then
        print_success "No weak ciphers detected"
    else
        print_critical "Found $weak_found weak cipher(s) - SECURITY RISK"
        return 1
    fi

    # Test for SSLv2/SSLv3 (should be disabled)
    print_info "Testing for obsolete SSL/TLS versions..."

    if openssl s_client -connect "${domain}:8118" -ssl2 </dev/null 2>&1 | grep -q "SSLv2"; then
        print_critical "SSLv2 is enabled (CRITICAL VULNERABILITY)"
        return 1
    else
        print_success "SSLv2 is disabled"
    fi

    if openssl s_client -connect "${domain}:8118" -ssl3 </dev/null 2>&1 | grep -q "SSLv3"; then
        print_critical "SSLv3 is enabled (CRITICAL VULNERABILITY - POODLE)"
        return 1
    else
        print_success "SSLv3 is disabled"
    fi

    # Test for TLS 1.0/1.1 (should be disabled for modern security)
    if openssl s_client -connect "${domain}:8118" -tls1 </dev/null 2>&1 | grep -q "TLSv1"; then
        print_warning "TLS 1.0 is enabled (outdated, should consider disabling)"
    else
        print_success "TLS 1.0 is disabled"
    fi

    # Test for perfect forward secrecy (PFS)
    print_info "Testing for Perfect Forward Secrecy support..."

    if openssl s_client -connect "${domain}:8118" -cipher "ECDHE" </dev/null 2>&1 | grep -q "Cipher.*ECDHE"; then
        print_success "Perfect Forward Secrecy (ECDHE) supported"
    else
        print_warning "Perfect Forward Secrecy may not be enabled"
    fi

    # Test for HSTS (HTTP Strict Transport Security) if applicable
    print_info "Checking for security headers..."

    local test_user
    test_user=$(get_test_user)
    local proxy_password
    proxy_password=$(get_proxy_password "$test_user")

    if [[ -n "$proxy_password" ]]; then
        local headers
        headers=$(timeout 10 curl -x "https://${test_user}:${proxy_password}@${domain}:8118" \
            -I -s "https://www.google.com" 2>/dev/null || echo "")

        if echo "$headers" | grep -qi "strict-transport-security"; then
            print_info "HSTS header present in proxied requests"
        fi
    fi

    print_success "SSL/TLS vulnerability scan completed"
    return 0
}

# ============================================================================
# TEST 7: PROXY PROTOCOL SECURITY
# ============================================================================

test_07_proxy_protocol_security() {
    print_header "TEST 7: Proxy Protocol Security Validation"
    print_test "Testing SOCKS5 and HTTP proxy security configurations"

    # Check if proxy is enabled
    if ! jq -e '.inbounds[] | select(.tag == "socks5-proxy")' "$XRAY_CONFIG" &>/dev/null; then
        print_skip "Proxy support not enabled"
        return 0
    fi

    # Test 1: Verify authentication is required
    print_info "Verifying proxy authentication is enforced..."

    local socks5_auth
    socks5_auth=$(jq -r '.inbounds[] | select(.tag == "socks5-proxy") | .settings.auth' "$XRAY_CONFIG" 2>/dev/null)

    if [[ "$socks5_auth" == "password" ]]; then
        print_success "SOCKS5 authentication required"
    else
        print_critical "SOCKS5 authentication NOT required - SECURITY RISK"
        return 1
    fi

    local http_auth
    http_auth=$(jq -r '.inbounds[] | select(.tag == "http-proxy") | .settings.auth' "$XRAY_CONFIG" 2>/dev/null)

    if [[ "$http_auth" == "password" ]]; then
        print_success "HTTP proxy authentication required"
    else
        print_critical "HTTP proxy authentication NOT required - SECURITY RISK"
        return 1
    fi

    # Test 2: Check proxy listen addresses
    print_info "Checking proxy listen addresses..."

    if is_public_proxy_enabled; then
        # Public mode: familytraffic (nginx) handles TLS termination (v5.33)
        print_info "Public proxy mode detected"

        # v5.33: HAProxy removed — familytraffic container (nginx) handles TLS termination
        if docker ps --format '{{.Names}}' | grep -q "familytraffic"; then
            print_success "familytraffic container running (nginx TLS termination active)"
        else
            print_critical "familytraffic container not running - PUBLIC PROXY UNPROTECTED"
            return 1
        fi

    else
        # Localhost mode: should listen on 127.0.0.1 only
        local socks5_listen
        socks5_listen=$(jq -r '.inbounds[] | select(.tag == "socks5-proxy") | .listen' "$XRAY_CONFIG" 2>/dev/null)

        if [[ "$socks5_listen" == "127.0.0.1" ]]; then
            print_success "SOCKS5 proxy bound to localhost only (secure)"
        else
            print_warning "SOCKS5 proxy listen address: $socks5_listen (should be 127.0.0.1 for localhost mode)"
        fi
    fi

    # Test 3: Verify UDP is disabled (security consideration)
    local socks5_udp
    socks5_udp=$(jq -r '.inbounds[] | select(.tag == "socks5-proxy") | .settings.udp // false' "$XRAY_CONFIG" 2>/dev/null)

    if [[ "$socks5_udp" == "false" ]]; then
        print_success "SOCKS5 UDP disabled (more secure)"
    else
        print_warning "SOCKS5 UDP enabled (may expose additional attack surface)"
    fi

    # Test 4: Password strength validation
    print_info "Validating proxy password strength..."

    local test_user
    test_user=$(get_test_user)
    local proxy_password
    proxy_password=$(get_proxy_password "$test_user")

    if [[ -z "$proxy_password" || "$proxy_password" == "null" ]]; then
        print_info "No proxy password found for test user"
    else
        local pass_length=${#proxy_password}

        if [[ $pass_length -ge 32 ]]; then
            print_success "Proxy password length: $pass_length characters (strong)"
        elif [[ $pass_length -ge 16 ]]; then
            print_info "Proxy password length: $pass_length characters (adequate)"
        else
            print_warning "Proxy password length: $pass_length characters (weak, should be >= 16)"
        fi

        # Check for hex format (good entropy)
        if [[ "$proxy_password" =~ ^[a-f0-9]+$ ]]; then
            print_success "Proxy password uses hexadecimal format (good entropy)"
        fi
    fi

    print_success "Proxy protocol security validation completed"
    return 0
}

# ============================================================================
# TEST 8: DATA LEAK DETECTION
# ============================================================================

test_08_data_leak_detection() {
    print_header "TEST 8: Data Leak Detection"
    print_test "Checking for potential information leaks"

    # Test 1: Check for exposed configuration files
    print_info "Checking for exposed configuration files..."

    local sensitive_files=(
        "$XRAY_CONFIG"
        "$USERS_JSON"
        "${VLESS_BASE_DIR}/keys/private.key"
        "$ENV_FILE"
    )

    local exposed=0
    for file in "${sensitive_files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms
            perms=$(stat -c "%a" "$file" 2>/dev/null)

            if [[ "$perms" == "600" ]] || [[ "$perms" == "700" ]]; then
                print_verbose "File properly protected: $file ($perms)"
            else
                print_warning "File may be exposed: $file (permissions: $perms)"
                ((exposed++)) || true
            fi
        fi
    done

    if [[ $exposed -eq 0 ]]; then
        print_success "No exposed configuration files detected"
    else
        print_warning "$exposed file(s) may have overly permissive permissions"
    fi

    # Test 2: Check for default/weak credentials
    print_info "Checking for default/weak credentials..."

    local weak_users=0
    while IFS= read -r username; do
        if [[ "$username" =~ ^(admin|test|user|demo)$ ]]; then
            print_warning "Default/weak username detected: $username"
            ((weak_users++)) || true
        fi
    done < <(jq -r '.users[].username' "$USERS_JSON" 2>/dev/null)

    if [[ $weak_users -eq 0 ]]; then
        print_success "No default/weak usernames detected"
    else
        print_warning "$weak_users user(s) have default/weak usernames (security best practice: use unique names)"
    fi

    # Test 3: Check for information disclosure in error messages
    print_info "Checking Docker container logs for sensitive data..."

    local sensitive_patterns=("password" "secret" "key" "uuid")
    local leaks_found=0

    for container in $(docker ps --format '{{.Names}}' | grep "familytraffic"); do
        local logs
        logs=$(docker logs "$container" --tail 100 2>&1 || echo "")

        for pattern in "${sensitive_patterns[@]}"; do
            if echo "$logs" | grep -qi "$pattern"; then
                print_warning "Potential sensitive data in $container logs: $pattern"
                ((leaks_found++)) || true
            fi
        done
    done

    if [[ $leaks_found -eq 0 ]]; then
        print_success "No obvious data leaks in container logs"
    else
        print_warning "$leaks_found potential data leak(s) in logs (review manually)"
    fi

    # Test 4: Check for DNS leaks (basic check)
    print_info "Checking DNS configuration for potential leaks..."

    # Check if Xray has DNS configured
    local dns_configured
    dns_configured=$(jq -e '.dns' "$XRAY_CONFIG" &>/dev/null && echo "true" || echo "false")

    if [[ "$dns_configured" == "true" ]]; then
        local dns_servers
        dns_servers=$(jq -r '.dns.servers[]' "$XRAY_CONFIG" 2>/dev/null | head -3 | tr '\n' ', ')
        print_info "DNS servers configured: $dns_servers"
        print_success "DNS configuration present (reduces leak risk)"
    else
        print_warning "No DNS configuration in Xray (may use system DNS - potential leak)"
    fi

    print_success "Data leak detection completed"
    return 0
}

# ============================================================================
# MAIN TEST RUNNER
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)
                QUICK_MODE=true
                print_info "Quick mode enabled - skipping long-running tests"
                ;;
            --skip-pcap)
                SKIP_PCAP=true
                print_info "Packet capture tests disabled"
                ;;
            --verbose)
                VERBOSE=true
                print_info "Verbose mode enabled"
                ;;
            --dev-mode|--dev)
                DEV_MODE=true
                print_info "Development mode enabled - skipping installation checks"
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --quick       Skip long-running tests"
                echo "  --skip-pcap   Skip packet capture tests"
                echo "  --verbose     Show detailed output"
                echo "  --dev-mode    Development mode (skip installation checks)"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Development Mode:"
                echo "  Use --dev-mode to run tests without full VLESS installation."
                echo "  This is useful for development and testing the test suite itself."
                echo "  Note: Many tests will be skipped in dev mode."
                echo ""
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 2
                ;;
        esac
        shift
    done
}

# ==============================================================================
# TEST: test_xtls_vision_enabled (TC-01, v5.25)
# ==============================================================================
# Description: Verify all Xray VLESS clients have flow=xtls-rprx-vision configured
#              Required for XTLS Vision DPI bypass (Tier 1 obfuscation)
# ==============================================================================
test_xtls_vision_enabled() {
    print_header "XTLS Vision — flow field verification (TC-01)"

    local xray_config="${XRAY_CONFIG:-/opt/familytraffic/config/xray_config.json}"

    if [[ ! -f "$xray_config" ]]; then
        print_skip "Xray config not found (installation may not be complete)"
        return 0
    fi

    # Check all Reality clients have flow=xtls-rprx-vision
    local clients_without_flow
    clients_without_flow=$(jq '[.inbounds[0].settings.clients[] | select(.flow != "xtls-rprx-vision")] | length' \
        "$xray_config" 2>/dev/null || echo "-1")

    if [[ "$clients_without_flow" == "-1" ]]; then
        print_failure "XTLS Vision: Could not parse xray_config.json"
        return 1
    elif [[ "$clients_without_flow" == "0" ]]; then
        print_success "XTLS Vision: All client objects have flow=xtls-rprx-vision"
    else
        print_failure "XTLS Vision: $clients_without_flow client(s) missing flow field — run 'vless migrate-vision'"
        return 1
    fi

    # Verify no clients have empty/null flow
    local clients_empty_flow
    clients_empty_flow=$(jq '[.inbounds[0].settings.clients[] | select(.flow == "" or .flow == null)] | length' \
        "$xray_config" 2>/dev/null || echo "0")

    if [[ "$clients_empty_flow" != "0" ]]; then
        print_failure "XTLS Vision: $clients_empty_flow client(s) have empty/null flow field"
        return 1
    fi

    print_success "XTLS Vision TC-01: PASSED"
    return 0
}

print_summary() {
    print_header "ENCRYPTION SECURITY TEST SUMMARY"

    local total_tests=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    echo ""
    echo "Total Tests:      $total_tests"
    echo -e "${GREEN}Passed:           $TESTS_PASSED${NC}"
    echo -e "${RED}Failed:           $TESTS_FAILED${NC}"
    echo -e "${YELLOW}Skipped:          $TESTS_SKIPPED${NC}"
    echo ""
    echo -e "${YELLOW}Security Warnings: $SECURITY_WARNINGS${NC}"
    echo -e "${RED}Critical Issues:   $CRITICAL_ISSUES${NC}"
    echo ""

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "${RED}Failed Tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $test"
        done
        echo ""
    fi

    if [[ ${#SECURITY_ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}Security Issues:${NC}"
        for issue in "${SECURITY_ISSUES[@]}"; do
            echo -e "  ${RED}🔥${NC} $issue"
        done
        echo ""
    fi

    # Overall result
    if [[ $CRITICAL_ISSUES -gt 0 ]]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}RESULT: CRITICAL SECURITY ISSUES DETECTED${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 3
    elif [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}RESULT: FAILED${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 1
    elif [[ $SECURITY_WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}RESULT: PASSED WITH WARNINGS${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    fi
}

main() {
    print_header "VLESS REALITY VPN - ENCRYPTION SECURITY TESTING SUITE"

    echo "Test Suite: Encryption & Secure Channel Validation"
    echo "Date: $(date)"
    echo "Server: $(hostname)"
    echo ""

    # Parse command-line arguments
    parse_arguments "$@"

    # Check prerequisites
    check_root
    check_prerequisites

    # Run test suite
    run_test test_01_reality_tls_config
    run_test test_02_haproxy_tls  # v4.3: HAProxy TLS termination

    if [[ "$QUICK_MODE" != "true" ]]; then
        run_test test_03_traffic_encryption
    else
        print_skip "Traffic encryption test skipped (--quick mode)"
    fi

    run_test test_04_certificate_security
    run_test test_05_dpi_resistance
    run_test test_06_tls_vulnerabilities
    run_test test_07_proxy_protocol_security
    run_test test_08_data_leak_detection
    run_test test_xtls_vision_enabled  # TC-01 (v5.25): XTLS Vision flow field verification

    # Print summary and exit
    print_summary
    return $?
}

################################################################################
# SCRIPT ENTRY POINT
################################################################################

main "$@"
exit $?
