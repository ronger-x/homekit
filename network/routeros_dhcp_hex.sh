#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  routeros_dhcp_hex.sh <IPv4>

Convert an IPv4 address to the RouterOS DHCP option hex format.

Examples:
  routeros_dhcp_hex.sh 192.168.88.169
  # 0xC0A858A9

  routeros_dhcp_hex.sh 192.168.88.113
  # 0xC0A85871
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

ip="$1"
IFS='.' read -r o1 o2 o3 o4 extra <<<"$ip"

if [[ -n "${extra:-}" || -z "${o1:-}" || -z "${o2:-}" || -z "${o3:-}" || -z "${o4:-}" ]]; then
    die "invalid IPv4 address: $ip"
fi

hex="0x"
for octet in "$o1" "$o2" "$o3" "$o4"; do
    if [[ ! "$octet" =~ ^[0-9]+$ ]]; then
        die "invalid IPv4 octet '$octet' in $ip"
    fi

    value=$((10#$octet))
    if (( value < 0 || value > 255 )); then
        die "IPv4 octet out of range '$octet' in $ip"
    fi

    printf -v byte '%02X' "$value"
    hex+="$byte"
done

printf '%s\n' "$hex"
