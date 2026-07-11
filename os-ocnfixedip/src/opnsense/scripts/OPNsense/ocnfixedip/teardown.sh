#!/bin/sh

# OCN Virtual Connect Fixed IP IPIP tunnel teardown script
# Removes gif tunnel interface and associated configuration

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

logger -t ocnfixedip "Tearing down OCN Virtual Connect Fixed IP tunnel"

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



# Remove periodic prefix update schedule/script
remove_prefix_update_cron
rm -f /usr/local/opnsense/scripts/OPNsense/ocnfixedip/prefix_update.sh

logger -t ocnfixedip "OCN Virtual Connect Fixed IP teardown complete"
exit 0
