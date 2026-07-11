#!/bin/sh

# OCN Virtual Connect Fixed IP (IPv4 over IPv6 IPIP) tunnel configuration script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

# Debounce frequent duplicate invocations (newwanip/config save race)
STAMP_FILE="/tmp/ocnfixedip_configure.stamp"
NOW=$(date +%s)
if [ -f "${STAMP_FILE}" ]; then
    LAST=$(cat "${STAMP_FILE}" 2>/dev/null)
    case "${LAST}" in
        ''|*[!0-9]*) LAST=0 ;;
    esac
    if [ $(( NOW - LAST )) -lt 3 ]; then
        logger -t ocnfixedip "Skipping duplicate configure trigger"
        exit 0
    fi
fi
echo "${NOW}" > "${STAMP_FILE}"

if [ "$1" = "restart" ]; then
    "${SCRIPT_DIR}/teardown.sh"
fi

if [ "${OCNFIXEDIP_ENABLED}" != "1" ]; then
    logger -t ocnfixedip "Service disabled, tearing down existing tunnel"
    "${SCRIPT_DIR}/teardown.sh"
    exit 0
fi

if [ -z "${FIXEDIP_AFTR}" ] || [ -z "${FIXEDIP_V4}" ]; then
    logger -t ocnfixedip "ERROR: BR IPv6 and tunnel local IPv4 are required"
    exit 1
fi

# Auto-calculate local tunnel IPv6 from WAN global IPv6 /64 and fixed IPv4.
# Interface-ID formula: ipv4(32bit) << 24  (e.g. 203.0.113.96 -> 00cb:0071:6000:0000)
WAN_GLOBAL_V6=$(get_wan_global_v6)
LOCAL_TUNNEL_V6=$(calc_local_tunnel_v6 "${WAN_GLOBAL_V6}" "${FIXEDIP_V4}")
if [ -z "${LOCAL_TUNNEL_V6}" ]; then
    logger -t ocnfixedip "ERROR: Failed to auto-calculate local tunnel IPv6 from WAN(${WAN_GLOBAL_V6}) and IPv4(${FIXEDIP_V4})"
    exit 1
fi
logger -t ocnfixedip "Auto-calculated local tunnel IPv6: ${LOCAL_TUNNEL_V6}"

if [ -z "${FIXEDIP_UPDATE_URL}" ] || [ -z "${FIXEDIP_AUTH_USER}" ]; then
    logger -t ocnfixedip "ERROR: Prefix update URL and Auth User are required"
    exit 1
fi

if tunnel_exists; then
    logger -t ocnfixedip "Removing existing tunnel interface ${TUNNEL_IF}"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
fi

ifconfig "${TUNNEL_IF}" create || {
    logger -t ocnfixedip "ERROR: Failed to create ${TUNNEL_IF}"
    exit 1
}

ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_TUNNEL_V6}" "${FIXEDIP_AFTR}" || {
    logger -t ocnfixedip "ERROR: Failed to set IPv6 tunnel endpoints"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    exit 1
}

ifconfig "${TUNNEL_IF}" inet "${FIXEDIP_V4}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.255 || {
    logger -t ocnfixedip "ERROR: Failed to set tunnel IPv4 addresses"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    exit 1
}

ifconfig "${TUNNEL_IF}" mtu "${MTU}"
sysctl net.inet.tcp.mss_ifmtu=1 >/dev/null 2>&1
ifconfig "${TUNNEL_IF}" up

# OCN Virtual Connect Fixed IP operation: IPv4 default route via gif peer (usually 192.0.0.1)
if route -n get default >/dev/null 2>&1; then
    if ! route change default "${AFTR_V4_ADDRESS}" 2>/dev/null; then
        logger -t ocnfixedip "WARNING: route change failed, trying delete/add"
        route delete default 2>/dev/null
        route add default "${AFTR_V4_ADDRESS}" 2>/dev/null || logger -t ocnfixedip "WARNING: Failed to set default route"
    fi
else
    route add default "${AFTR_V4_ADDRESS}" 2>/dev/null || logger -t ocnfixedip "WARNING: Failed to add default route"
fi

# Verify route convergence (best-effort)
if ! route -n get default 2>/dev/null | grep -q "gateway: ${AFTR_V4_ADDRESS}"; then
    logger -t ocnfixedip "WARNING: default route gateway is not ${AFTR_V4_ADDRESS} yet"
fi



# Immediate prefix update
UPDATE_URL="${FIXEDIP_UPDATE_URL}"
if [ -n "${FIXEDIP_UPDATE_HOSTNAME}" ] && ! printf '%s' "${UPDATE_URL}" | grep -q 'hostname='; then
    case "${UPDATE_URL}" in
        *\?*) UPDATE_URL="${UPDATE_URL}&hostname=${FIXEDIP_UPDATE_HOSTNAME}" ;;
        *) UPDATE_URL="${UPDATE_URL}?hostname=${FIXEDIP_UPDATE_HOSTNAME}" ;;
    esac
fi
logger -t ocnfixedip "Sending prefix update to ${UPDATE_URL}"
UPDATE_RESULT=$(curl -6 -sk -u "${FIXEDIP_AUTH_USER}:${FIXEDIP_AUTH_PASS}" "${UPDATE_URL}" 2>&1)
logger -t ocnfixedip "Prefix update response: ${UPDATE_RESULT}"

# Cleanup legacy periodic prefix update artifacts (migration from cron-based versions)
remove_prefix_update_cron
rm -f /usr/local/opnsense/scripts/OPNsense/ocnfixedip/prefix_update.sh

logger -t ocnfixedip "OCN Virtual Connect Fixed IP tunnel configuration complete"
exit 0
