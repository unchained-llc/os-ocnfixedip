#!/bin/sh

# OCN Fixed IP (IPoE) (IPv4 over IPv6 IPIP) shared library functions

TUNNEL_IF="gif0"
CONFIG_XML="/conf/config.xml"

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
    ifconfig "${wan_if}" 2>/dev/null | awk '/inet6 / && $2 !~ /^fe80:/ && $2 !~ /^::1/ {gsub(/%.*/, "", $2); print $2; exit}'
}

get_wan_global_v6_with_retry() {
    local attempts="${1:-6}"
    local delay="${2:-1}"
    local i=0
    local v6=""

    while [ "${i}" -lt "${attempts}" ]; do
        v6=$(get_wan_global_v6)
        if [ -n "${v6}" ]; then
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
wan = ipaddress.ip_address(sys.argv[1])
v4 = int(ipaddress.ip_address(sys.argv[2]))
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
    route -n get default 2>/dev/null | grep -q "interface: ${TUNNEL_IF}"
}


