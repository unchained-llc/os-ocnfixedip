#!/bin/sh

# OCN Fixed IP (IPoE) IPIP status script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

append_failure() {
    local key="$1"
    if [ -z "${health_failures}" ]; then
        health_failures="${key}"
    else
        health_failures="${health_failures},${key}"
    fi
}

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

    health="degraded"
    health_failures=""

    br_v6_target="${FIXEDIP_AFTR:-${remote_v6}}"
    ce_source="${local_v6}"
    if [ -z "${ce_source}" ] && [ -f /var/run/ocnfixedip_local_tunnel_v6 ]; then
        ce_source=$(cat /var/run/ocnfixedip_local_tunnel_v6 2>/dev/null)
    fi

    # 1) Tunnel state
    if [ "${status}" != "up" ]; then
        append_failure "tunnel_state"
    fi

    # 2) Default route check (default -> 192.0.0.1 via gif0)
    route_info=$(route -n get default 2>/dev/null)
    route_gateway=$(printf '%s' "${route_info}" | awk -F': ' '/gateway:/ {print $2; exit}')
    route_iface=$(printf '%s' "${route_info}" | awk -F': ' '/interface:/ {print $2; exit}')
    if [ "${route_gateway}" != "192.0.0.1" ] || [ "${route_iface}" != "${TUNNEL_IF}" ]; then
        append_failure "default_route"
    fi

    # 3) DNS resolution check
    resolve_name="one.one.one.one"
    resolve_answer=""
    if command -v drill >/dev/null 2>&1; then
        resolve_answer=$(drill "${resolve_name}" A 2>/dev/null | awk '/\tIN\tA\t/ {print $5; exit}')
    elif command -v host >/dev/null 2>&1; then
        resolve_answer=$(host -t A "${resolve_name}" 2>/dev/null | awk '/has address/ {print $NF; exit}')
    elif command -v getent >/dev/null 2>&1; then
        resolve_answer=$(getent hosts "${resolve_name}" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -n "${resolve_answer}" ] || append_failure "dns"

    # 4) MTU configured vs actual
    expected_mtu="${MTU:-1460}"
    if [ -z "${mtu_val}" ] || [ "${mtu_val}" != "${expected_mtu}" ]; then
        append_failure "mtu"
    fi

    # 5) WAN /128 alias presence check
    wan_if_device=$(get_wan_if_device)
    if [ -n "${ce_source}" ] && [ -n "${wan_if_device}" ] && ifconfig "${wan_if_device}" >/dev/null 2>&1; then
        if ! ifconfig "${wan_if_device}" 2>/dev/null | awk '/inet6 / {gsub(/%.*/, "", $2); print $2}' | grep -qx "${ce_source}"; then
            append_failure "wan_alias"
        fi
    else
        append_failure "wan_alias"
    fi

    # 6) Prefix update last result check (recorded on configure/apply)
    if [ -f /var/run/ocnfixedip_prefix_update_status ]; then
        prefix_state=$(cat /var/run/ocnfixedip_prefix_update_status 2>/dev/null)
        prefix_rc=$(printf '%s' "${prefix_state}" | awk '{print $2; exit}')
        prefix_code=$(printf '%s' "${prefix_state}" | awk '{print $3; exit}')
        if [ "${prefix_rc}" != "0" ]; then
            append_failure "prefix_update"
        else
            case "${prefix_code}" in
                good|nochg) : ;;
                *) append_failure "prefix_update" ;;
            esac
        fi
    else
        append_failure "prefix_update"
    fi

    # Connectivity / MTU probes require tunnel IPv4
    if [ -z "${ipv4}" ]; then
        connectivity="no internet"
        reason="No IPv4 address on tunnel interface"
        append_failure "internet"
        append_failure "ipv6_internet"
        append_failure "mtu_probe"
        append_failure "mtu_fragmentation"
    else
        # 7) BR ping from CE address
        if [ -z "${br_v6_target}" ]; then
            connectivity="no internet"
            reason="BR endpoint is not configured"
            append_failure "ce_to_br"
        elif [ -z "${ce_source}" ]; then
            connectivity="no internet"
            reason="CE source IPv6 is unavailable"
            append_failure "ce_to_br"
        elif ping -6 -c 1 -W 2 -S "${ce_source}" "${br_v6_target}" >/dev/null 2>&1; then
            # 8) Internet IPv4 ping from tunnel IPv4
            if ping -c 1 -W 2 -S "${ipv4}" 1.1.1.1 >/dev/null 2>&1; then
                connectivity="connected"
            else
                connectivity="no internet"
                reason="BR reachable from CE (${ce_source} -> ${br_v6_target}), but Internet ping failed (1.1.1.1)"
                append_failure "internet"
            fi
        else
            connectivity="no internet"
            reason="BR unreachable from CE (${ce_source} -> ${br_v6_target})"
            append_failure "ce_to_br"
            append_failure "internet"
        fi

        # 9) IPv6 internet ping from CE source
        if [ -n "${ce_source}" ]; then
            if ! ping -6 -c 1 -W 2 -S "${ce_source}" 2606:4700:4700::1111 >/dev/null 2>&1; then
                append_failure "ipv6_internet"
            fi
        else
            append_failure "ipv6_internet"
        fi

        # 10) MTU DF probe (exact MTU)
        if [ -n "${mtu_val}" ] && [ "${mtu_val}" -ge 1280 ] 2>/dev/null; then
            mtu_probe_payload=$(( mtu_val - 28 ))
            if [ "${mtu_probe_payload}" -gt 0 ] 2>/dev/null; then
                ping -D -c 1 -W 2 -S "${ipv4}" -s "${mtu_probe_payload}" 1.1.1.1 >/dev/null 2>&1 || append_failure "mtu_probe"
            else
                append_failure "mtu_probe"
            fi

            # 11) Large packet fragmentation test (DF off)
            mtu_frag_payload=$(( mtu_val + 100 - 28 ))
            if [ "${mtu_frag_payload}" -gt 0 ] 2>/dev/null; then
                ping -c 1 -W 2 -S "${ipv4}" -s "${mtu_frag_payload}" 1.1.1.1 >/dev/null 2>&1 || append_failure "mtu_fragmentation"
            else
                append_failure "mtu_fragmentation"
            fi
        else
            append_failure "mtu_probe"
            append_failure "mtu_fragmentation"
        fi
    fi

    if [ -z "${health_failures}" ] && [ "${status}" = "up" ] && [ "${connectivity}" = "connected" ]; then
        health="healthy"
    else
        health="degraded"
    fi

    printf '{"tunnel":{"status":"%s","connectivity":"%s","health":"%s","health_failures":"%s","local_v6":"%s","aftr":"%s","ipv4":"%s","mtu":"%s","interface":"%s","reason":"%s"}}' \
        "${status}" "${connectivity}" "${health}" "${health_failures}" "${local_v6}" "${remote_v6}" "${ipv4}" "${mtu_val}" "${TUNNEL_IF}" "${reason}"
else
    get_config
    if [ "${OCNFIXEDIP_ENABLED}" = "1" ]; then
        printf '{"tunnel":{"status":"not configured","connectivity":"offline","health":"offline","health_failures":"tunnel_state","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Not started - click Apply"}}' "${TUNNEL_IF}"
    else
        printf '{"tunnel":{"status":"disabled","connectivity":"offline","health":"offline","health_failures":"","local_v6":"-","aftr":"-","ipv4":"-","mtu":"-","interface":"%s","reason":"Service is disabled"}}' "${TUNNEL_IF}"
    fi
fi
