#!/usr/bin/env bash
# Common utility functions for familytraffic

# Guard against double sourcing: modules source this directly rather than
# relying on the CLI's load order, so it can be reached more than once.
if [[ -n "${FAMILYTRAFFIC_COMMON_LOADED:-}" ]]; then
    return 0
fi
FAMILYTRAFFIC_COMMON_LOADED=1

# Write temp file content to target preserving inode (required for Docker bind mounts).
# Docker file bind mounts are tied to the file's inode. Using 'mv' replaces the
# directory entry with a new inode, so the container keeps seeing stale content.
# 'cat src > dst' writes into the existing file, preserving its inode.
#
# Usage: write_preserving_inode "$temp_file" "$target_file"
write_preserving_inode() {
    local src="$1" dst="$2"
    if [[ ! -f "$src" ]]; then
        echo "write_preserving_inode: source not found: $src" >&2
        return 1
    fi
    cat "$src" > "$dst" && rm -f "$src"
}

# Validate an IPv4 or IPv6 address, with an optional CIDR prefix.
#
# The prefix range follows the address family: 0-32 for IPv4, 0-128 for IPv6.
# An earlier copy of this function in ufw_whitelist.sh capped every prefix at 32
# and so rejected ordinary IPv6 networks such as 2001:db8::/64; because the CLI
# sourced that module last, its version shadowed the correct one. Both modules
# now share this single definition.
#
# IPv6 matching is deliberately shape-based rather than exhaustive: it accepts
# the hex-group form used by the whitelists and rejects anything with characters
# outside that alphabet. Callers report their own error messages, so this stays
# silent and only returns a status.
#
# Usage: validate_ip "192.168.1.0/24"  |  validate_ip "2001:db8::/64"
validate_ip() {
    local ip="$1"

    [[ -z "$ip" ]] && return 1

    local addr="${ip%%/*}"
    local prefix=""
    if [[ "$ip" == *"/"* ]]; then
        prefix="${ip##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    fi

    if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        IFS='.' read -ra octets <<< "$addr"
        for octet in "${octets[@]}"; do
            [[ "$octet" -gt 255 ]] && return 1
        done
        [[ -n "$prefix" && "$prefix" -gt 32 ]] && return 1
        return 0
    fi

    if [[ "$addr" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
        [[ -n "$prefix" && "$prefix" -gt 128 ]] && return 1
        return 0
    fi

    return 1
}
