#!/bin/sh

# DS-Lite / Fixed IP tunnel configuration script
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

# Determine tunnel parameters based on mode
TUNNEL_MODE=$(config_get "//OPNsense/dslite/mode")
TUNNEL_MODE="${TUNNEL_MODE:-dslite}"

if [ "${TUNNEL_MODE}" = "fixedip" ]; then
    # Fixed IP mode: use member-specific parameters from Asahi Net / v6 Connect
    FIXEDIP_INTERFACE_ID=$(config_get "//OPNsense/dslite/fixedip_interface_id")
    FIXEDIP_AFTR=$(config_get "//OPNsense/dslite/fixedip_aftr")
    FIXEDIP_V4=$(config_get "//OPNsense/dslite/fixedip_v4")
    FIXEDIP_UPDATE_URL=$(config_get "//OPNsense/dslite/fixedip_update_url")
    FIXEDIP_AUTH_USER=$(config_get "//OPNsense/dslite/fixedip_auth_user")
    FIXEDIP_AUTH_PASS=$(config_get "//OPNsense/dslite/fixedip_auth_pass")

    if [ -z "${FIXEDIP_INTERFACE_ID}" ] || [ -z "${FIXEDIP_AFTR}" ] || [ -z "${FIXEDIP_V4}" ]; then
        logger -t dslite "ERROR: Fixed IP mode requires Interface ID, AFTR endpoint, and Fixed IPv4 address"
        exit 1
    fi

    # Use the Interface ID as the local tunnel source
    LOCAL_V6="${FIXEDIP_INTERFACE_ID}"
    AFTR_ADDRESS="${FIXEDIP_AFTR}"

    # For fixed IP, the tunnel IPv4 is the fixed public address
    # The remote side is a point-to-point, we use the fixed IP as our address
    B4_ADDRESS="${FIXEDIP_V4}"
    # AFTR v4 side - use a /32 point-to-point (no peer address needed for IPIP)
    AFTR_V4_ADDRESS=""

    # Assign the Interface ID to the WAN interface if not present
    WAN_IF=$(config_get "//interfaces/${WAN_INTERFACE}/if")
    WAN_IF="${WAN_IF:-${WAN_INTERFACE}}"
    if ! ifconfig "${WAN_IF}" 2>/dev/null | grep -q "${LOCAL_V6}"; then
        ifconfig "${WAN_IF}" inet6 "${LOCAL_V6}" prefixlen 128
        logger -t dslite "Assigned Interface ID ${LOCAL_V6} to ${WAN_IF}"
        sleep 2
    fi

    # Run prefix update if configured
    if [ -n "${FIXEDIP_UPDATE_URL}" ] && [ -n "${FIXEDIP_AUTH_USER}" ]; then
        logger -t dslite "Sending prefix update to ${FIXEDIP_UPDATE_URL}"
        curl -6 -sk -u "${FIXEDIP_AUTH_USER}:${FIXEDIP_AUTH_PASS}" "${FIXEDIP_UPDATE_URL}" 2>/dev/null
        if [ $? -eq 0 ]; then
            logger -t dslite "Prefix update sent successfully"
        else
            logger -t dslite "WARNING: Prefix update failed (tunnel may still work)"
        fi
    fi

    logger -t dslite "Fixed IP mode: local=${LOCAL_V6} aftr=${AFTR_ADDRESS} ipv4=${B4_ADDRESS}"
else
    # Standard DS-Lite mode
    if [ -z "${AFTR_ADDRESS}" ]; then
        logger -t dslite "ERROR: No AFTR address configured or resolved"
        exit 1
    fi

    # Get WAN IPv6 address (global scope)
    LOCAL_V6=$(get_wan_ipv6)

    # If no global address, try to derive one from DHCPv6-PD prefix
    if [ -z "${LOCAL_V6}" ]; then
        logger -t dslite "No global IPv6 on WAN, attempting to derive from PD prefix"
        PD_PREFIX=$(get_pd_prefix)
        if [ -n "${PD_PREFIX}" ]; then
            BASE_PREFIX=$(echo "${PD_PREFIX}" | sed 's|/.*||; s/::$//')
            LOCAL_V6="${BASE_PREFIX}::1"
            WAN_IF=$(config_get "//interfaces/${WAN_INTERFACE}/if")
            WAN_IF="${WAN_IF:-${WAN_INTERFACE}}"
            if ! ifconfig "${WAN_IF}" 2>/dev/null | grep -q "${LOCAL_V6}"; then
                ifconfig "${WAN_IF}" inet6 "${LOCAL_V6}" prefixlen 128
                logger -t dslite "Assigned ${LOCAL_V6} to ${WAN_IF} from PD prefix ${PD_PREFIX}"
                sleep 2
            fi
        fi
    fi

    if [ -z "${LOCAL_V6}" ]; then
        logger -t dslite "ERROR: No global IPv6 address found on WAN interface (${WAN_INTERFACE})"
        exit 1
    fi

    logger -t dslite "DS-Lite mode: local=${LOCAL_V6} aftr=${AFTR_ADDRESS}"
fi

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
ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_V6}" "${AFTR_ADDRESS}"
if [ $? -ne 0 ]; then
    logger -t dslite "ERROR: Failed to set tunnel endpoints"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    exit 1
fi

# Configure IPv4 addresses on tunnel
if [ "${TUNNEL_MODE}" = "fixedip" ]; then
    # Fixed IP: assign the public IPv4 directly to the tunnel interface
    ifconfig "${TUNNEL_IF}" inet "${B4_ADDRESS}" netmask 255.255.255.255
    logger -t dslite "Fixed IP ${B4_ADDRESS} assigned to ${TUNNEL_IF}"
else
    # DS-Lite: standard B4/AFTR point-to-point (RFC 6333)
    ifconfig "${TUNNEL_IF}" inet "${B4_ADDRESS}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.248
fi

# Set MTU
ifconfig "${TUNNEL_IF}" mtu "${MTU}"

# Bring interface up
ifconfig "${TUNNEL_IF}" up

logger -t dslite "Tunnel ${TUNNEL_IF} created via ${AFTR_ADDRESS}"

# Add default IPv4 route through tunnel
route delete default 2>/dev/null
if [ "${TUNNEL_MODE}" = "fixedip" ]; then
    # For IPIP tunnel, route via the tunnel interface directly
    route add default -interface "${TUNNEL_IF}" 2>/dev/null
else
    route add default "${AFTR_V4_ADDRESS}" 2>/dev/null
fi

if [ $? -ne 0 ]; then
    logger -t dslite "WARNING: Failed to add default route"
fi

logger -t dslite "Default IPv4 route set"

# Configure NAT and firewall rules via OPNsense's registered anchors
if [ "${NAT_ENABLED}" = "1" ]; then
    NAT_FILE="/tmp/dslite_nat.conf"
    if [ "${TUNNEL_MODE}" = "fixedip" ]; then
        # Fixed IP: NAT to the public fixed IP
        cat > "${NAT_FILE}" << EOF
nat on ${TUNNEL_IF} from any to any -> ${B4_ADDRESS}
EOF
    else
        # DS-Lite: NAT to tunnel interface address
        cat > "${NAT_FILE}" << EOF
nat on ${TUNNEL_IF} from any to any -> (${TUNNEL_IF})
EOF
    fi

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
        logger -t dslite "WARNING: Failed to load NAT anchor, trying filter reload"
        configctl filter reload 2>/dev/null
        sleep 1
        pfctl -a "dslite/nat" -f "${NAT_FILE}" 2>/dev/null
    fi

    pfctl -a "dslite/fw" -f "${FW_FILE}" 2>/dev/null
    if [ $? -eq 0 ]; then
        logger -t dslite "Firewall rules loaded for ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to load firewall anchor"
    fi
fi

# Set up periodic prefix update cron job for Fixed IP mode
if [ "${TUNNEL_MODE}" = "fixedip" ] && [ -n "${FIXEDIP_UPDATE_URL}" ] && [ -n "${FIXEDIP_AUTH_USER}" ]; then
    CRON_FILE="/usr/local/opnsense/scripts/OPNsense/dslite/prefix_update.sh"
    cat > "${CRON_FILE}" << CRONEOF
#!/bin/sh
# DS-Lite Fixed IP prefix update
curl -6 -sk -u "${FIXEDIP_AUTH_USER}:${FIXEDIP_AUTH_PASS}" "${FIXEDIP_UPDATE_URL}" 2>/dev/null
if [ \$? -eq 0 ]; then
    logger -t dslite "Periodic prefix update sent"
else
    logger -t dslite "WARNING: Periodic prefix update failed"
fi
CRONEOF
    chmod +x "${CRON_FILE}"
    logger -t dslite "Prefix update script created"
fi

logger -t dslite "Tunnel configuration complete (mode: ${TUNNEL_MODE})"
exit 0
