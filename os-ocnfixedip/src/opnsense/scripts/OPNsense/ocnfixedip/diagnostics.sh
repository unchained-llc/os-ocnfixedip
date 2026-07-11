#!/bin/sh

# OCN Virtual Connect Fixed IP IPIP diagnostics script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

iface_info=$(ifconfig "${TUNNEL_IF}" 2>&1)
route_info=$(netstat -rn -f inet 2>&1 | head -20)

ping_info="Not tested"
if ifconfig "${TUNNEL_IF}" >/dev/null 2>&1; then
    tunnel_ipv4=$(ifconfig "${TUNNEL_IF}" 2>/dev/null | awk '/inet / {print $2; exit}')
    if [ -n "${tunnel_ipv4}" ]; then
        ping_info=$(ping -c 3 -W 2 -S "${tunnel_ipv4}" 8.8.8.8 2>&1)
    else
        ping_info="No IPv4 address on tunnel interface"
    fi
fi

escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | \
        awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

iface_esc=$(escape_json "${iface_info}")
route_esc=$(escape_json "${route_info}")
ping_esc=$(escape_json "${ping_info}")
printf '{"interface":"%s","routes":"%s","ping":"%s"}' \
    "${iface_esc}" "${route_esc}" "${ping_esc}"
