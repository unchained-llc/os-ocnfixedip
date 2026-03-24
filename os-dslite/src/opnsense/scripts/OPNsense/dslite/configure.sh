#!/bin/sh

# DS-Lite tunnel configuration script
# Creates gif tunnel interface for IPv4-in-IPv6 encapsulation

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

# Load configuration
get_config

# Check if we should tear down first (restart)
if [ "$1" = "restart" ]; then
    "${SCRIPT_DIR}/teardown.sh"
fi

# Bail out if not enabled
if [ "${DSLITE_ENABLED}" != "1" ]; then
    logger -t dslite "DS-Lite is disabled, tearing down any existing tunnel"
    "${SCRIPT_DIR}/teardown.sh"
    exit 0
fi

# Validate required configuration
if [ -z "${AFTR_ADDRESS}" ]; then
    logger -t dslite "ERROR: No AFTR address configured or resolved"
    exit 1
fi

# Get WAN IPv6 address (global scope)
LOCAL_V6=$(get_wan_ipv6)

# If no global address, try to derive one from DHCPv6-PD prefix
# NTT IPoE typically only provides PD, not IA-NA
if [ -z "${LOCAL_V6}" ]; then
    logger -t dslite "No global IPv6 on WAN, attempting to derive from PD prefix"
    PD_PREFIX=$(get_pd_prefix)
    if [ -n "${PD_PREFIX}" ]; then
        # Use ::1 from the first /64 of the delegated prefix as our WAN address
        BASE_PREFIX=$(echo "${PD_PREFIX}" | sed 's|/.*||; s/::$//')
        LOCAL_V6="${BASE_PREFIX}::1"
        WAN_IF=$(config_get "//interfaces/${WAN_INTERFACE}/if")
        WAN_IF="${WAN_IF:-${WAN_INTERFACE}}"

        # Assign the address to the WAN interface if not already present
        if ! ifconfig "${WAN_IF}" 2>/dev/null | grep -q "${LOCAL_V6}"; then
            ifconfig "${WAN_IF}" inet6 "${LOCAL_V6}" prefixlen 128
            logger -t dslite "Assigned ${LOCAL_V6} to ${WAN_IF} from PD prefix ${PD_PREFIX}"
            # Wait for DAD (Duplicate Address Detection)
            sleep 2
        fi
    fi
fi

if [ -z "${LOCAL_V6}" ]; then
    logger -t dslite "ERROR: No global IPv6 address found on WAN interface (${WAN_INTERFACE})"
    exit 1
fi

logger -t dslite "Configuring DS-Lite tunnel: local=${LOCAL_V6} aftr=${AFTR_ADDRESS}"

# Tear down existing tunnel if present
if tunnel_exists; then
    logger -t dslite "Removing existing tunnel interface ${TUNNEL_IF}"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
fi

# Create gif tunnel interface
ifconfig "${TUNNEL_IF}" create
if [ $? -ne 0 ]; then
    logger -t dslite "ERROR: Failed to create ${TUNNEL_IF}"
    exit 1
fi

# Configure IPv6 tunnel endpoints (IPv4-in-IPv6)
# FreeBSD gif requires 'inet6 tunnel' for IPv6 endpoints
ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_V6}" "${AFTR_ADDRESS}"
if [ $? -ne 0 ]; then
    logger -t dslite "ERROR: Failed to set tunnel endpoints"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    exit 1
fi

# Configure IPv4 point-to-point addresses (RFC 6333)
ifconfig "${TUNNEL_IF}" inet "${B4_ADDRESS}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.248

# Set MTU
ifconfig "${TUNNEL_IF}" mtu "${MTU}"

# Bring interface up
ifconfig "${TUNNEL_IF}" up

logger -t dslite "Tunnel ${TUNNEL_IF} created: ${B4_ADDRESS} -> ${AFTR_V4_ADDRESS} via ${AFTR_ADDRESS}"

# Add default IPv4 route through tunnel
# Remove any existing default route through our tunnel first
route delete default "${AFTR_V4_ADDRESS}" 2>/dev/null
route add default "${AFTR_V4_ADDRESS}" 2>/dev/null
if [ $? -ne 0 ]; then
    logger -t dslite "WARNING: Failed to add default route via ${AFTR_V4_ADDRESS}"
fi

logger -t dslite "Default IPv4 route set via ${AFTR_V4_ADDRESS}"

# Configure NAT and firewall rules via OPNsense's registered anchors
if [ "${NAT_ENABLED}" = "1" ]; then
    NAT_FILE="/tmp/dslite_nat.conf"
    cat > "${NAT_FILE}" << EOF
nat on ${TUNNEL_IF} from any to any -> (${TUNNEL_IF})
EOF

    FW_FILE="/tmp/dslite_fw.conf"
    cat > "${FW_FILE}" << EOF
pass out quick on ${TUNNEL_IF} all keep state
pass in quick on ${TUNNEL_IF} all keep state
EOF

    # Load into OPNsense's registered anchors
    pfctl -a "dslite/nat" -f "${NAT_FILE}" 2>/dev/null
    if [ $? -eq 0 ]; then
        logger -t dslite "NAT rules loaded for ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to load NAT anchor, trying direct load"
        # Fallback: reload entire filter to pick up anchor registration
        configctl filter reload 2>/dev/null
        sleep 1
        pfctl -a "dslite/nat" -f "${NAT_FILE}" 2>/dev/null
    fi

    pfctl -a "dslite/fw" -f "${FW_FILE}" 2>/dev/null
    if [ $? -eq 0 ]; then
        logger -t dslite "Firewall and MSS rules loaded for ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to load firewall anchor"
    fi
fi

logger -t dslite "DS-Lite tunnel configuration complete"
exit 0
