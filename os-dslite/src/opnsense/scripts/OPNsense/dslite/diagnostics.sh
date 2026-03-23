#!/bin/sh

# DS-Lite diagnostics script
# Returns JSON with comprehensive tunnel diagnostics

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

TUNNEL_IF="gif0"

# Collect diagnostics
iface_info=$(ifconfig "${TUNNEL_IF}" 2>&1)
route_info=$(netstat -rn -f inet 2>&1 | head -20)
nat_info=$(pfctl -a "dslite" -s nat 2>&1)

# Get WAN IPv6
get_config
wan_v6_info=$(get_wan_ipv6 2>&1)

# Connectivity test through tunnel
ping_info="Not tested"
if ifconfig "${TUNNEL_IF}" >/dev/null 2>&1; then
    ping_result=$(ping -c 3 -W 2 -S 192.0.0.2 8.8.8.8 2>&1)
    ping_info="${ping_result}"
fi

# Escape strings for JSON
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | \
        awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

iface_esc=$(escape_json "${iface_info}")
route_esc=$(escape_json "${route_info}")
ping_esc=$(escape_json "${ping_info}")
v6_esc=$(escape_json "${wan_v6_info}")
nat_esc=$(escape_json "${nat_info}")

printf '{"interface":"%s","routes":"%s","ping":"%s","ipv6":"%s","nat":"%s"}' \
    "${iface_esc}" "${route_esc}" "${ping_esc}" "${v6_esc}" "${nat_esc}"
