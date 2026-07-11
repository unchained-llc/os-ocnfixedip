#!/bin/sh

# OCN Fixed IP (IPoE) (IPv4 over IPv6 IPIP) tunnel configuration script

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

# Auto-calculate local tunnel IPv6 from WAN global IPv6 /56 and fixed IPv4.
# Interface-ID formula: ipv4(32bit) << 24  (e.g. 203.0.113.96 -> 00cb:0071:6000:0000)
WAN_GLOBAL_V6=$(get_wan_global_v6_with_retry 6 1)
LOCAL_TUNNEL_V6=$(calc_local_tunnel_v6 "${WAN_GLOBAL_V6}" "${FIXEDIP_V4}")
if [ -z "${LOCAL_TUNNEL_V6}" ]; then
    logger -t ocnfixedip "ERROR: Failed to auto-calculate local tunnel IPv6 from WAN(${WAN_GLOBAL_V6}) and IPv4(${FIXEDIP_V4})"
    exit 1
fi
logger -t ocnfixedip "Auto-calculated local tunnel IPv6: ${LOCAL_TUNNEL_V6}"

# Ensure WAN has local tunnel IPv6 as /128 alias.
# Without this, gif0 may remain non-running after reconfigure timing races.
# Also remove stale previously-managed alias when prefix changes.
WAN_IF_DEVICE=$(get_wan_if_device)
STATE_FILE="/var/run/ocnfixedip_local_tunnel_v6"
if ifconfig "${WAN_IF_DEVICE}" >/dev/null 2>&1; then
    PREV_LOCAL_TUNNEL_V6=""
    if [ -f "${STATE_FILE}" ]; then
        PREV_LOCAL_TUNNEL_V6=$(cat "${STATE_FILE}" 2>/dev/null)
    fi

    if [ -n "${PREV_LOCAL_TUNNEL_V6}" ] && [ "${PREV_LOCAL_TUNNEL_V6}" != "${LOCAL_TUNNEL_V6}" ]; then
        if ifconfig "${WAN_IF_DEVICE}" 2>/dev/null | awk '/inet6 / {gsub(/%.*/, "", $2); print $2}' | grep -qx "${PREV_LOCAL_TUNNEL_V6}"; then
            if ifconfig "${WAN_IF_DEVICE}" inet6 "${PREV_LOCAL_TUNNEL_V6}" -alias 2>/dev/null; then
                logger -t ocnfixedip "Removed stale WAN /128 alias on ${WAN_IF_DEVICE}: ${PREV_LOCAL_TUNNEL_V6}"
            else
                logger -t ocnfixedip "WARNING: Failed to remove stale WAN /128 alias on ${WAN_IF_DEVICE}: ${PREV_LOCAL_TUNNEL_V6}"
            fi
        fi
    fi

    if ! ifconfig "${WAN_IF_DEVICE}" 2>/dev/null | awk '/inet6 / {gsub(/%.*/, "", $2); print $2}' | grep -qx "${LOCAL_TUNNEL_V6}"; then
        if ifconfig "${WAN_IF_DEVICE}" inet6 "${LOCAL_TUNNEL_V6}"/128 alias 2>/dev/null; then
            logger -t ocnfixedip "Added WAN /128 alias for local tunnel IPv6 on ${WAN_IF_DEVICE}: ${LOCAL_TUNNEL_V6}"
        else
            logger -t ocnfixedip "ERROR: Failed to add WAN /128 alias on ${WAN_IF_DEVICE}: ${LOCAL_TUNNEL_V6}"
            exit 1
        fi
    fi

    echo "${LOCAL_TUNNEL_V6}" > "${STATE_FILE}"
else
    logger -t ocnfixedip "ERROR: WAN interface device not found: ${WAN_IF_DEVICE}"
    exit 1
fi

if [ -z "${FIXEDIP_UPDATE_URL}" ] || [ -z "${FIXEDIP_AUTH_USER}" ]; then
    logger -t ocnfixedip "ERROR: Prefix update URL and Auth User are required"
    exit 1
fi

if ! tunnel_exists; then
    ifconfig "${TUNNEL_IF}" create || {
        logger -t ocnfixedip "ERROR: Failed to create ${TUNNEL_IF}"
        exit 1
    }
    logger -t ocnfixedip "Created tunnel interface ${TUNNEL_IF}"
fi

ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_TUNNEL_V6}" "${FIXEDIP_AFTR}" || {
    logger -t ocnfixedip "ERROR: Failed to set IPv6 tunnel endpoints"
    exit 1
}

ifconfig "${TUNNEL_IF}" inet "${FIXEDIP_V4}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.255 || {
    logger -t ocnfixedip "ERROR: Failed to set tunnel IPv4 addresses"
    exit 1
}

ifconfig "${TUNNEL_IF}" mtu "${MTU}"
sysctl net.inet.tcp.mss_ifmtu=1 >/dev/null 2>&1
ifconfig "${TUNNEL_IF}" up

# Best-effort auto-assignment so gateway/NAT can be configured from GUI
# without manual config.xml edits on first setup.
if [ -x /usr/local/bin/php ]; then
    AUTO_ASSIGN_RESULT=$(/usr/local/bin/php <<'PHP'
<?php
$cfginc = '/usr/local/etc/inc/config.inc';
if (!file_exists($cfginc)) {
    exit(1);
}
require_once($cfginc);

$target = 'gif0';
$descr = 'TUNNEL';

if (!isset($config) || !is_array($config)) {
    exit(1);
}
if (!isset($config['interfaces']) || !is_array($config['interfaces'])) {
    $config['interfaces'] = [];
}

$existing = null;
foreach ($config['interfaces'] as $ifname => $ifcfg) {
    if (is_array($ifcfg) && !empty($ifcfg['if']) && $ifcfg['if'] === $target) {
        $existing = $ifname;
        break;
    }
}
if ($existing !== null) {
    echo "existing:${existing}";
    exit(0);
}

$idx = 1;
while (isset($config['interfaces']["opt{$idx}"])) {
    $idx++;
}
$newif = "opt{$idx}";
$config['interfaces'][$newif] = [
    'if' => $target,
    'descr' => $descr,
    'enable' => '1',
];

write_config("OCN Fixed IP (IPoE): auto-assign gif0 to {$newif}");
echo "created:${newif}";
PHP
)
    case "${AUTO_ASSIGN_RESULT}" in
        created:*)
            logger -t ocnfixedip "Auto-assigned ${TUNNEL_IF} as ${AUTO_ASSIGN_RESULT#created:} (descr=TUNNEL)"
            ;;
        existing:*)
            logger -t ocnfixedip "Tunnel interface already assigned as ${AUTO_ASSIGN_RESULT#existing:}"
            ;;
        *)
            logger -t ocnfixedip "WARNING: Auto-assignment skipped for ${TUNNEL_IF}"
            ;;
    esac
else
    logger -t ocnfixedip "WARNING: /usr/local/bin/php not found; skipped auto-assignment for ${TUNNEL_IF}"
fi

# OCN Fixed IP (IPoE) operation: IPv4 default route via gif peer (usually 192.0.0.1)
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
NETRC=$(mktemp /tmp/ocnfixedip-netrc.XXXXXX)
chmod 600 "${NETRC}"
printf "default\nlogin %s\npassword %s\n" "${FIXEDIP_AUTH_USER}" "${FIXEDIP_AUTH_PASS}" > "${NETRC}"
UPDATE_RESULT=$(curl -6 -sk --netrc-file "${NETRC}" "${UPDATE_URL}" 2>&1)
rm -f "${NETRC}"
logger -t ocnfixedip "Prefix update response: ${UPDATE_RESULT}"

logger -t ocnfixedip "OCN Fixed IP (IPoE) tunnel configuration complete"
exit 0
