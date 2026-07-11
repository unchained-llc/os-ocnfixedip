#!/bin/sh

# OPNsense OCN Fixed IP (IPoE) Plugin Uninstaller

set -e

echo "=== OPNsense OCN Fixed IP (IPoE) Plugin Uninstaller ==="
echo ""

# Stop tunnel if running
echo "Stopping OCN Fixed IP (IPoE) tunnel..."
configctl ocnfixedip stop 2>/dev/null || true

# Remove files
echo "Removing plugin files..."
rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP
rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP
rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP
rm -rf /usr/local/opnsense/scripts/OPNsense/ocnfixedip
rm -f /usr/local/opnsense/service/conf/actions.d/actions_ocnfixedip.conf
rm -f /usr/local/etc/inc/plugins.inc.d/ocnfixedip.inc
rm -f /usr/local/opnsense/www/js/widgets/OCNFixedIP.js
rm -f /usr/local/opnsense/www/js/widgets/Metadata/OCNFixedIP.xml

# Cleanup tunnel
ifconfig gif0 destroy 2>/dev/null || true
# Do not blindly delete system default route on uninstall

opnsense-patch

# Restart configd
echo "Restarting configd..."
service configd restart

# Flush caches
rm -rf /tmp/opnsense_*cache* 2>/dev/null
rm -f /tmp/ocnfixedip_*.conf 2>/dev/null

echo ""
echo "=== Uninstall complete ==="
echo "Log out and back into the web UI for menu changes to take effect."
echo "Note: OCN Fixed IP (IPoE) config in /conf/config.xml was not removed."
echo ""
