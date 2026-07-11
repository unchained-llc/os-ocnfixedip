#!/bin/sh

# OCN Fixed IP (IPoE) IPIP diagnostics script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

iface_info=$(ifconfig "${TUNNEL_IF}" 2>&1)
route_info=$(netstat -rn -f inet 2>&1 | head -20)

ping_info="Not tested"
if ifconfig "${TUNNEL_IF}" >/dev/null 2>&1; then
    tunnel_ipv4=$(ifconfig "${TUNNEL_IF}" 2>/dev/null | awk '/inet / {print $2; exit}')
    br_v6_target="${FIXEDIP_AFTR}"
    if [ -z "${br_v6_target}" ]; then
        br_v6_target=$(ifconfig "${TUNNEL_IF}" 2>/dev/null | awk '/tunnel inet6/ {print $5; exit}')
    fi

    if [ -n "${tunnel_ipv4}" ]; then
        if [ -n "${br_v6_target}" ]; then
            br_ping=$(ping -6 -c 3 -W 2 "${br_v6_target}" 2>&1)
        else
            br_ping="BR endpoint is not configured"
        fi
        inet_ping=$(ping -c 3 -W 2 -S "${tunnel_ipv4}" 1.1.1.1 2>&1)
        ping_info=$(printf '=== BR Ping (%s) ===\n%s\n\n=== Internet Ping (1.1.1.1) ===\n%s' "${br_v6_target:-N/A}" "${br_ping}" "${inet_ping}")
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
