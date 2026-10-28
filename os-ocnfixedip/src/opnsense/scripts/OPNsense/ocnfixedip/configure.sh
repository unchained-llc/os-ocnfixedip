#!/bin/sh

# OCN Fixed IP (IPoE) (IPv4 over IPv6 IPIP) tunnel configuration script

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

# Configure, restart and stop share a kernel lock. No time-based request skipping.
if [ "${1:-}" != "--locked" ]; then
    exec python3 "${SCRIPT_DIR}/runtime.py" lock "${RUNTIME_LOCK}" /bin/sh "$0" --locked "$@"
fi
shift
umask 077
get_config
PHASE="validation"
WARNING=""
MUTATED=0
rollback() {
    logger -t ocnfixedip "Attempting to restore network state after failed configure"
    remove_managed_alias || return 1
    if [ -n "${OLD_ALIAS}" ]; then
        if [ "${OLD_ALIAS_OWNED}" = "1" ] && [ "${OLD_ALIAS_PRESENT}" = "1" ]; then
            alias_exists "${OLD_ALIAS_IF}" "${OLD_ALIAS_V6}" || ifconfig "${OLD_ALIAS_IF}" inet6 "${OLD_ALIAS_V6}/128" alias >/dev/null 2>&1 || return 1
        fi
        printf '%s\n' "${OLD_ALIAS}" > "${STATE_FILE}" || return 1
    fi
    if [ -n "${OLD_LOCAL}" ] && [ -n "${OLD_REMOTE}" ] && [ -n "${OLD_IPV4}" ]; then
        tunnel_exists || ifconfig "${TUNNEL_IF}" create >/dev/null 2>&1 || return 1
        ifconfig "${TUNNEL_IF}" inet6 tunnel "${OLD_LOCAL}" "${OLD_REMOTE}" >/dev/null 2>&1 || return 1
        ifconfig "${TUNNEL_IF}" inet "${OLD_IPV4}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.255 >/dev/null 2>&1 || return 1
        ifconfig "${TUNNEL_IF}" mtu "${OLD_MTU}" >/dev/null 2>&1 || return 1
        ifconfig "${TUNNEL_IF}" "${OLD_UP}" >/dev/null 2>&1 || return 1
    elif tunnel_exists; then
        ifconfig "${TUNNEL_IF}" destroy >/dev/null 2>&1 || return 1
    fi
    CURRENT_GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
    if [ -n "${OLD_GATEWAY}" ] && [ "${CURRENT_GATEWAY}" != "${OLD_GATEWAY}" ]; then
        route change default "${OLD_GATEWAY}" >/dev/null 2>&1 || route add default "${OLD_GATEWAY}" >/dev/null 2>&1 || return 1
    elif [ -z "${OLD_GATEWAY}" ] && default_route_uses_tunnel; then
        route delete default >/dev/null 2>&1 || return 1
    fi
    if [ "${OLD_SYSCTL}" != "unsupported" ]; then
        sysctl "net.inet.tcp.mss_ifmtu=${OLD_SYSCTL}" >/dev/null 2>&1 || return 1
    fi
    if [ "${HAD_SYSCTL_STATE}" = "0" ]; then
        rm -f "${SYSCTL_STATE}"
    else
        printf '%s\n' "${BASE_SYSCTL}" > "${SYSCTL_STATE}" || return 1
    fi
}
finish() {
    rc=$?
    trap - 0
    if [ "${rc}" -ne 0 ] && [ "${MUTATED}" = "1" ]; then
        if ! rollback; then
            logger -t ocnfixedip "ERROR: rollback incomplete; inspect tunnel, route and WAN aliases"
            WARNING="rollback"
        fi
    fi
    invalidate_status
    if [ "${rc}" -eq 0 ]; then
        render_json '{"result":"%s","phase":"%s","warning":"%s"}' ok "${PHASE}" "${WARNING}"
    else
        render_json '{"result":"%s","phase":"%s","warning":"%s"}' failed "${PHASE}" "${WARNING}"
    fi
}
trap finish 0
trap 'exit 1' HUP INT TERM
fail() {
    logger -t ocnfixedip "ERROR: configure failed at ${PHASE}"
    exit 1
}
invalidate_status

if [ "${OCNFIXEDIP_ENABLED}" != "1" ]; then
    PHASE="stop"
    "${SCRIPT_DIR}/teardown.sh" --locked >/dev/null || fail
    exit 0
fi

for tool in python3 curl xmllint ifconfig route sysctl; do
    command -v "${tool}" >/dev/null 2>&1 || fail
done
update_input | python3 "${SCRIPT_DIR}/runtime.py" validate-update >/dev/null || fail

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

# Validate everything before an explicit restart tears down working state.
WAN_IF_DEVICE=$(get_wan_if_device)
ifconfig "${WAN_IF_DEVICE}" >/dev/null 2>&1 || fail
# Capture rollback data while holding the runtime lock, before any mutation.
OLD_IFDATA=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
OLD_LOCAL=$(printf '%s' "${OLD_IFDATA}" | awk '/tunnel inet6/ {print $3; exit}')
OLD_REMOTE=$(printf '%s' "${OLD_IFDATA}" | awk '/tunnel inet6/ {print $5; exit}')
OLD_IPV4=$(printf '%s' "${OLD_IFDATA}" | awk '/inet / {print $2; exit}')
OLD_MTU=$(printf '%s' "${OLD_IFDATA}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)
OLD_UP=down
printf '%s' "${OLD_IFDATA}" | grep -q UP && OLD_UP=up
OLD_GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
OLD_SYSCTL=$(sysctl -n net.inet.tcp.mss_ifmtu 2>/dev/null) || OLD_SYSCTL=unsupported
case "${OLD_SYSCTL}" in unsupported) : ;; ''|*[!0-9]*) fail ;; esac
HAD_SYSCTL_STATE=0
BASE_SYSCTL="${OLD_SYSCTL}"
if [ -f "${SYSCTL_STATE}" ]; then
    HAD_SYSCTL_STATE=1
    BASE_SYSCTL=$(cat "${SYSCTL_STATE}")
    case "${BASE_SYSCTL}" in ''|*[!0-9]*) fail ;; esac
fi
OLD_ALIAS=$(cat "${STATE_FILE}" 2>/dev/null)
read_alias_state
OLD_ALIAS_IF="${ALIAS_IF}"; OLD_ALIAS_V6="${ALIAS_V6}"; OLD_ALIAS_OWNED="${ALIAS_OWNED}"
OLD_ALIAS_PRESENT=0
if [ -n "${OLD_ALIAS_IF}" ] && alias_exists "${OLD_ALIAS_IF}" "${OLD_ALIAS_V6}"; then OLD_ALIAS_PRESENT=1; fi
# Refuse to overwrite another service's configured gif0.
HAS_ENDPOINT=0
printf '%s' "${OLD_IFDATA}" | grep -q 'tunnel inet' && HAS_ENDPOINT=1
OLD_INNER_V6=$(printf '%s' "${OLD_IFDATA}" | awk '/^[[:space:]]*inet6 / && $2 !~ /^fe80:/ {print $2; exit}')
if { [ "${HAS_ENDPOINT}" = "1" ] || [ -n "${OLD_LOCAL}${OLD_IPV4}${OLD_INNER_V6}" ]; } && { [ -z "${OLD_ALIAS_V6}" ] || [ "${OLD_LOCAL}" != "${OLD_ALIAS_V6}" ]; } && ! tunnel_matches_config "${OLD_IFDATA}"; then
    PHASE="ownership"
    fail
fi
MUTATED=1
if [ "${1:-}" = "restart" ]; then
    PHASE="stop"
    "${SCRIPT_DIR}/teardown.sh" --locked >/dev/null || fail
fi

PHASE="wan_alias"
read_alias_state
if [ -n "${ALIAS_V6}" ] && { [ "${ALIAS_IF}" != "${WAN_IF_DEVICE}" ] || [ "${ALIAS_V6}" != "${LOCAL_TUNNEL_V6}" ]; }; then
    remove_managed_alias || fail
    ALIAS_OWNED=0
fi
OWNED="${ALIAS_OWNED:-0}"
# Preserve any matching address that existed before the plugin, regardless of prefix length.
if ! address_exists "${WAN_IF_DEVICE}" "${LOCAL_TUNNEL_V6}"; then
    ifconfig "${WAN_IF_DEVICE}" inet6 "${LOCAL_TUNNEL_V6}"/128 alias >/dev/null 2>&1 || fail
    OWNED=1
fi
printf '%s %s %s\n' "${WAN_IF_DEVICE}" "${LOCAL_TUNNEL_V6}" "${OWNED}" > "${STATE_FILE}" || fail

PHASE="tunnel"
if ! tunnel_exists; then
    ifconfig "${TUNNEL_IF}" create >/dev/null 2>&1 || {
        logger -t ocnfixedip "ERROR: Failed to create ${TUNNEL_IF}"
        exit 1
    }
    logger -t ocnfixedip "Created tunnel interface ${TUNNEL_IF}"
fi

ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_TUNNEL_V6}" "${FIXEDIP_AFTR}" >/dev/null 2>&1 || {
    logger -t ocnfixedip "ERROR: Failed to set IPv6 tunnel endpoints"
    exit 1
}

ifconfig "${TUNNEL_IF}" inet "${FIXEDIP_V4}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.255 >/dev/null 2>&1 || {
    logger -t ocnfixedip "ERROR: Failed to set tunnel IPv4 addresses"
    exit 1
}

ifconfig "${TUNNEL_IF}" mtu "${MTU}" >/dev/null 2>&1 || fail
if [ "${OLD_SYSCTL}" != "unsupported" ]; then
    if [ ! -f "${SYSCTL_STATE}" ]; then
        printf '%s\n' "${BASE_SYSCTL}" > "${SYSCTL_STATE}" || fail
    fi
    sysctl net.inet.tcp.mss_ifmtu=1 >/dev/null 2>&1 || fail
else
    logger -t ocnfixedip "Optional TCP MSS sysctl is unavailable; using configured firewall MSS normalization"
fi
ifconfig "${TUNNEL_IF}" up >/dev/null 2>&1 || fail

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

PHASE="default_route"
if route -n get default >/dev/null 2>&1; then
    if ! route change default "${AFTR_V4_ADDRESS}" >/dev/null 2>&1; then
        route delete default >/dev/null 2>&1 || fail
        route add default "${AFTR_V4_ADDRESS}" >/dev/null 2>&1 || fail
    fi
else
    route add default "${AFTR_V4_ADDRESS}" >/dev/null 2>&1 || fail
fi
route -n get default 2>/dev/null | awk '/gateway:/ {print $2}' | grep -Fqx "${AFTR_V4_ADDRESS}" || fail
default_route_uses_tunnel || fail

PHASE="prefix_update"
logger -t ocnfixedip "Sending prefix update (URL and hostname omitted)"
UPDATE_RESULT=$(run_prefix_update) || fail
UPDATE_CODE=$(printf '%s' "${UPDATE_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])') || fail
logger -t ocnfixedip "Prefix update result: ${UPDATE_CODE}"
case "${UPDATE_CODE}" in
    good|nochg) : ;;
    *) WARNING="prefix_update" ;;
esac
PHASE="complete"
logger -t ocnfixedip "OCN Fixed IP (IPoE) tunnel configuration complete"
exit 0
