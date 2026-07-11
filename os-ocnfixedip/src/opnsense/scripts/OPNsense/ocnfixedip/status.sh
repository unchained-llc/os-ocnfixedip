#!/bin/sh

# OCN Fixed IP (IPoE) IPIP status script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

if tunnel_exists; then
    ifdata=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    status="down"
    echo "${ifdata}" | grep -q "RUNNING" && status="up"

    local_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {print $3}')
    remote_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {print $5}')
    ipv4=$(echo "${ifdata}" | awk '/inet / {print $2; exit}')
    mtu_val=$(echo "${ifdata}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)

    connectivity="untested"
    reason=""
    br_v6_target="${FIXEDIP_AFTR:-${remote_v6}}"
    if [ "${status}" = "up" ] && [ -n "${ipv4}" ]; then
        if [ -z "${br_v6_target}" ]; then
            connectivity="no internet"
            reason="BR endpoint is not configured"
        elif ping -6 -c 1 -W 2 "${br_v6_target}" >/dev/null 2>&1; then
            if ping -c 1 -W 2 -S "${ipv4}" 1.1.1.1 >/dev/null 2>&1; then
                connectivity="connected"
            else
                connectivity="no internet"
                reason="BR reachable (${br_v6_target}), but Internet ping failed (1.1.1.1)"
            fi
        else
            connectivity="no internet"
            reason="BR unreachable (${br_v6_target})"
        fi
    fi

    printf '{"tunnel":{"status":"%s","connectivity":"%s","local_v6":"%s","aftr":"%s","ipv4":"%s","mtu":"%s","interface":"%s","reason":"%s"}}' \
        "${status}" "${connectivity}" "${local_v6}" "${remote_v6}" "${ipv4}" "${mtu_val}" "${TUNNEL_IF}" "${reason}"
else
    get_config
    if [ "${OCNFIXEDIP_ENABLED}" = "1" ]; then
        printf '{"tunnel":{"status":"not configured","connectivity":"offline","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Not started - click Apply"}}' "${TUNNEL_IF}"
    else
        printf '{"tunnel":{"status":"disabled","connectivity":"offline","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Service is disabled"}}' "${TUNNEL_IF}"
    fi
fi
