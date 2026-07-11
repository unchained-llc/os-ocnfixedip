#!/bin/sh

# OCN Virtual Connect Fixed IP IPIP status script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

if tunnel_exists; then
    ifdata=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    status="down"
    echo "${ifdata}" | grep -q "RUNNING" && status="up"

    local_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {print $3}')
    remote_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {print $5}')
    ipv4=$(echo "${ifdata}" | awk '/inet / {print $2; exit}')
    mtu_val=$(echo "${ifdata}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)

    connectivity="untested"
    if [ "${status}" = "up" ] && [ -n "${ipv4}" ]; then
        if ping -c 1 -W 2 -S "${ipv4}" 8.8.8.8 >/dev/null 2>&1; then
            connectivity="connected"
        else
            connectivity="no internet"
        fi
    fi

    printf '{"tunnel":{"status":"%s","connectivity":"%s","local_v6":"%s","aftr":"%s","ipv4":"%s","mtu":"%s","interface":"%s"}}' \
        "${status}" "${connectivity}" "${local_v6}" "${remote_v6}" "${ipv4}" "${mtu_val}" "${TUNNEL_IF}"
else
    get_config
    if [ "${OCNFIXEDIP_ENABLED}" = "1" ]; then
        printf '{"tunnel":{"status":"not configured","connectivity":"offline","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Not started - click Apply"}}' "${TUNNEL_IF}"
    else
        printf '{"tunnel":{"status":"disabled","connectivity":"offline","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Service is disabled"}}' "${TUNNEL_IF}"
    fi
fi
