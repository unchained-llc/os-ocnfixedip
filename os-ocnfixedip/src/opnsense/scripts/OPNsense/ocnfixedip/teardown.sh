#!/bin/sh

# OCN Fixed IP (IPoE) IPIP tunnel teardown script
# Removes gif tunnel interface and associated configuration

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

if [ "${1:-}" != "--locked" ]; then
    exec python3 "${SCRIPT_DIR}/runtime.py" lock "${RUNTIME_LOCK}" /bin/sh "$0" --locked
fi
get_config
invalidate_status
trap invalidate_status 0
logger -t ocnfixedip "Tearing down OCN Fixed IP (IPoE) tunnel"

# Never stop another service's gif0 (including uninstall before first Apply).
read_alias_state
OWN_TUNNEL=0
if tunnel_exists; then
    IFDATA=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    CURRENT_LOCAL=$(printf '%s' "${IFDATA}" | awk '/tunnel inet6/ {print $3; exit}')
    CURRENT_IPV4=$(printf '%s' "${IFDATA}" | awk '/inet / {print $2; exit}')
    HAS_ENDPOINT=0
    printf '%s' "${IFDATA}" | grep -q 'tunnel inet' && HAS_ENDPOINT=1
    CURRENT_INNER_V6=$(printf '%s' "${IFDATA}" | awk '/^[[:space:]]*inet6 / && $2 !~ /^fe80:/ {print $2; exit}')
    if { [ -n "${ALIAS_V6}" ] && [ "${CURRENT_LOCAL}" = "${ALIAS_V6}" ]; } || tunnel_matches_config "${IFDATA}" || { [ "${HAS_ENDPOINT}" = "0" ] && [ -z "${CURRENT_LOCAL}${CURRENT_IPV4}${CURRENT_INNER_V6}" ]; }; then
        OWN_TUNNEL=1
    else
        logger -t ocnfixedip "Preserving gif0 configured outside this plugin"
    fi
fi

# Remove the default route only while it uses our owned tunnel.
if [ "${OWN_TUNNEL}" = "1" ] && default_route_uses_tunnel; then
    route delete default >/dev/null 2>&1 || exit 1
fi

# Destroy only the owned tunnel or the empty package-created interface.
if [ "${OWN_TUNNEL}" = "1" ]; then
    ifconfig "${TUNNEL_IF}" destroy >/dev/null 2>&1 || exit 1
    logger -t ocnfixedip "Tunnel interface ${TUNNEL_IF} destroyed"
else
    logger -t ocnfixedip "No owned tunnel to destroy"
fi

# Keep the ownership record when deletion fails so the next stop can retry.
remove_managed_alias || exit 1
if [ -f "${SYSCTL_STATE}" ]; then
    PREV_SYSCTL=$(cat "${SYSCTL_STATE}")
    case "${PREV_SYSCTL}" in ''|*[!0-9]*) exit 1 ;; esac
    if sysctl -n net.inet.tcp.mss_ifmtu >/dev/null 2>&1; then
        sysctl "net.inet.tcp.mss_ifmtu=${PREV_SYSCTL}" >/dev/null 2>&1 || exit 1
    fi
    rm -f "${SYSCTL_STATE}"
fi

logger -t ocnfixedip "OCN Fixed IP (IPoE) teardown complete"
exit 0
