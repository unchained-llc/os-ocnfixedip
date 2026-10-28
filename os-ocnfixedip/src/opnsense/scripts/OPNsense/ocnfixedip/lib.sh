#!/bin/sh

# OCN Fixed IP (IPoE) (IPv4 over IPv6 IPIP) shared library functions

TUNNEL_IF="gif0"
CONFIG_XML="/conf/config.xml"
STATE_FILE="/var/run/ocnfixedip_local_tunnel_v6"
PREFIX_STATE="/var/run/ocnfixedip_prefix_update_status"
STATUS_CACHE="/var/run/ocnfixedip_status.json"
RUNTIME_LOCK="/var/run/ocnfixedip.lock"
SYSCTL_STATE="/var/run/ocnfixedip_mss_ifmtu"

render_json() {
    python3 "${SCRIPT_DIR}/runtime.py" json "$@"
}

update_input() {
    printf '%s\000%s\000%s\000%s' "${FIXEDIP_AUTH_USER}" "${FIXEDIP_AUTH_PASS}" "${FIXEDIP_UPDATE_HOSTNAME}" "${FIXEDIP_UPDATE_URL}"
}

run_prefix_update() {
    update_input | python3 "${SCRIPT_DIR}/runtime.py" update "${PREFIX_STATE}"
}

invalidate_status() {
    rm -f "${STATUS_CACHE}"
}

# A two-column record is owned; legacy one-column records are migrated only
# when the configured WAN actually carries that /128 address.
read_alias_state() {
    ALIAS_IF=""; ALIAS_V6=""; ALIAS_OWNED=0
    [ -f "${STATE_FILE}" ] || return 0
    read -r ALIAS_IF ALIAS_V6 ALIAS_OWNED < "${STATE_FILE}"
    if [ -z "${ALIAS_V6}" ]; then
        ALIAS_V6="${ALIAS_IF}"
        ALIAS_IF=$(get_wan_if_device)
        ALIAS_OWNED=1
    fi
}

address_exists() {
    ifconfig "$1" 2>/dev/null | awk '/inet6 / {gsub(/%.*/, "", $2); print $2}' | grep -Fqx -- "$2"
}

alias_exists() {
    ifconfig "$1" 2>/dev/null | awk '/inet6 / && /prefixlen 128([[:space:]]|$)/ {gsub(/%.*/, "", $2); print $2}' | grep -Fqx -- "$2"
}

remove_managed_alias() {
    read_alias_state
    if [ "${ALIAS_OWNED}" = "1" ] && [ -n "${ALIAS_IF}" ] && [ -n "${ALIAS_V6}" ] && alias_exists "${ALIAS_IF}" "${ALIAS_V6}"; then
        ifconfig "${ALIAS_IF}" inet6 "${ALIAS_V6}" -alias >/dev/null 2>&1 || return 1
        logger -t ocnfixedip "Removed managed WAN /128 alias on ${ALIAS_IF}"
    fi
    rm -f "${STATE_FILE}"
}

config_get() {
    local xpath="$1"
    /usr/local/bin/xmllint --xpath "string(${xpath})" "${CONFIG_XML}" 2>/dev/null
}

get_config() {
    OCNFIXEDIP_ENABLED=$(config_get "//OPNsense/ocnfixedip/enabled")
    WAN_INTERFACE=$(config_get "//OPNsense/ocnfixedip/wan_interface")

    FIXEDIP_AFTR=$(config_get "//OPNsense/ocnfixedip/fixedip_aftr")
    FIXEDIP_V4=$(config_get "//OPNsense/ocnfixedip/fixedip_v4")

    MTU=$(config_get "//OPNsense/ocnfixedip/mtu")

    FIXEDIP_UPDATE_URL=$(config_get "//OPNsense/ocnfixedip/fixedip_update_url")
    FIXEDIP_UPDATE_HOSTNAME=$(config_get "//OPNsense/ocnfixedip/fixedip_update_hostname")
    FIXEDIP_AUTH_USER=$(config_get "//OPNsense/ocnfixedip/fixedip_auth_user")
    FIXEDIP_AUTH_PASS=$(config_get "//OPNsense/ocnfixedip/fixedip_auth_pass")

    AFTR_V4_ADDRESS="192.0.0.1"
    MTU="${MTU:-1460}"
}

get_wan_if_device() {
    local wan_if
    wan_if=$(config_get "//interfaces/${WAN_INTERFACE}/if")
    [ -n "${wan_if}" ] || wan_if="${WAN_INTERFACE}"
    printf '%s' "${wan_if}"
}

get_wan_global_v6() {
    local wan_if
    wan_if=$(get_wan_if_device)
    read_alias_state
    EXCLUDED_ALIAS=""
    [ "${ALIAS_OWNED}" = "1" ] && EXCLUDED_ALIAS="${ALIAS_V6}"
    ifconfig "${wan_if}" 2>/dev/null | python3 "${SCRIPT_DIR}/runtime.py" select-ipv6 "${EXCLUDED_ALIAS}" 2>/dev/null
}

get_wan_global_v6_with_retry() {
    local attempts="${1:-6}"
    local delay="${2:-1}"
    local i=0
    local v6=""

    while [ "${i}" -lt "${attempts}" ]; do
        v6=$(get_wan_global_v6)
        if [ $? -eq 0 ] && [ -n "${v6}" ]; then
            printf '%s' "${v6}"
            return 0
        fi
        i=$(( i + 1 ))
        [ "${i}" -lt "${attempts}" ] && sleep "${delay}"
    done

    return 1
}

calc_local_tunnel_v6() {
    local wan_v6="$1"
    local v4="$2"

    [ -n "${wan_v6}" ] || return 1
    [ -n "${v4}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    python3 -c '
import ipaddress, sys
wan = ipaddress.IPv6Address(sys.argv[1])
v4 = int(ipaddress.IPv4Address(sys.argv[2]))
net56 = ipaddress.ip_network(str(wan) + "/56", strict=False)
iface_id = v4 << 24
addr = int(net56.network_address) | iface_id
print(ipaddress.ip_address(addr))
' "${wan_v6}" "${v4}" 2>/dev/null
}

tunnel_exists() {
    ifconfig "${TUNNEL_IF}" >/dev/null 2>&1
}

default_route_uses_tunnel() {
    route -n get default 2>/dev/null | awk '/interface:/ {print $2}' | grep -Fqx "${TUNNEL_IF}"
}



# OPNsense restores assigned GIFs during boot, before volatile ownership state exists.
# Adopt only a tunnel matching this service's BR, IPv4/peer and address formula.
tunnel_matches_config() {
    local data="$1" local_v6 remote_v6 local_v4 peer_v4 expected
    local_v6=$(printf '%s' "${data}" | awk '/tunnel inet6/ {print $3; exit}')
    remote_v6=$(printf '%s' "${data}" | awk '/tunnel inet6/ {print $5; exit}')
    local_v4=$(printf '%s' "${data}" | awk '/^[[:space:]]*inet / {print $2; exit}')
    peer_v4=$(printf '%s' "${data}" | awk '/^[[:space:]]*inet / {print $4; exit}')
    [ "${remote_v6}" = "${FIXEDIP_AFTR}" ] && [ "${local_v4}" = "${FIXEDIP_V4}" ] && [ "${peer_v4}" = "${AFTR_V4_ADDRESS}" ] || return 1
    expected=$(calc_local_tunnel_v6 "${local_v6}" "${FIXEDIP_V4}") || return 1
    [ "${expected}" = "${local_v6}" ]
}
