#!/bin/sh

# OCN Fixed IP (IPoE) IPIP tunnel teardown script
# Removes gif tunnel interface and associated configuration

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

logger -t ocnfixedip "Tearing down OCN Fixed IP (IPoE) tunnel"

# Remove default route only if it currently uses this tunnel
if default_route_uses_tunnel; then
    route delete default 2>/dev/null
fi

# Destroy tunnel interface
if tunnel_exists; then
    ifconfig "${TUNNEL_IF}" down 2>/dev/null
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    logger -t ocnfixedip "Tunnel interface ${TUNNEL_IF} destroyed"
else
    logger -t ocnfixedip "Tunnel interface ${TUNNEL_IF} not found"
fi

# Cleanup tracked local tunnel IPv6 alias state
rm -f /var/run/ocnfixedip_local_tunnel_v6

logger -t ocnfixedip "OCN Fixed IP (IPoE) teardown complete"
exit 0
