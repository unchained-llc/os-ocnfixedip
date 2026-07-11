#!/bin/sh

# OPNsense OCN Fixed IP (IPoE) Plugin Installer
# Local/offline installer (no GitHub download)
# 1) Copy this directory to OPNsense via scp
# 2) Run: sh /path/to/os-ocnfixedip/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/src"

echo "=== OPNsense OCN Fixed IP (IPoE) Plugin Installer ==="
echo ""

if [ ! -f /usr/local/etc/inc/plugins.inc.d/pf.inc ]; then
    echo "ERROR: This script must be run on an OPNsense system."
    exit 1
fi

if [ ! -f "${SRC}/opnsense/service/conf/actions.d/actions_ocnfixedip.conf" ]; then
    echo "ERROR: Source files not found under ${SRC}"
    echo "       Please run this script from inside the os-ocnfixedip directory copied to OPNsense."
    exit 1
fi

echo "Installing plugin files from local source: ${SRC}"

mkdir -p /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL
mkdir -p /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu
cp "${SRC}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/OCNFixedIP.xml" /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/
cp "${SRC}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/OCNFixedIP.php" /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/
cp "${SRC}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL/ACL.xml" /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL/
cp "${SRC}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu/Menu.xml" /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu/

mkdir -p /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api
mkdir -p /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms
cp "${SRC}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/GeneralController.php" /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/
cp "${SRC}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/DiagnosticsController.php" /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/
cp "${SRC}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/SettingsController.php" /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/
cp "${SRC}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/ServiceController.php" /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/
cp "${SRC}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml" /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/

mkdir -p /usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP
cp "${SRC}/opnsense/mvc/app/views/OPNsense/OCNFixedIP/general.volt" /usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP/
cp "${SRC}/opnsense/mvc/app/views/OPNsense/OCNFixedIP/diagnostics.volt" /usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP/

mkdir -p /usr/local/opnsense/www/js/widgets/Metadata
cp "${SRC}/opnsense/www/js/widgets/OCNFixedIP.js" /usr/local/opnsense/www/js/widgets/
cp "${SRC}/opnsense/www/js/widgets/Metadata/OCNFixedIP.xml" /usr/local/opnsense/www/js/widgets/Metadata/

mkdir -p /usr/local/opnsense/scripts/OPNsense/ocnfixedip
cp "${SRC}/opnsense/scripts/OPNsense/ocnfixedip/"*.sh /usr/local/opnsense/scripts/OPNsense/ocnfixedip/
chmod +x /usr/local/opnsense/scripts/OPNsense/ocnfixedip/*.sh

cp "${SRC}/opnsense/service/conf/actions.d/actions_ocnfixedip.conf" /usr/local/opnsense/service/conf/actions.d/
cp "${SRC}/etc/inc/plugins.inc.d/ocnfixedip.inc" /usr/local/etc/inc/plugins.inc.d/

echo "Removing legacy DSLite leftovers..."
rm -rf \
    /usr/local/opnsense/mvc/app/models/OPNsense/DSLite \
    /usr/local/opnsense/mvc/app/controllers/OPNsense/DSLite \
    /usr/local/opnsense/mvc/app/views/OPNsense/DSLite \
    /usr/local/opnsense/scripts/OPNsense/dslite 2>/dev/null || true
rm -f \
    /usr/local/etc/inc/plugins.inc.d/dslite.inc \
    /usr/local/opnsense/service/conf/actions.d/actions_dslite.conf \
    /usr/local/opnsense/www/js/widgets/DSLite.js \
    /usr/local/opnsense/www/js/widgets/Metadata/DSLite.xml 2>/dev/null || true

opnsense-patch

echo "Restarting configd..."
service configd restart

rm -rf /tmp/opnsense_*cache* 2>/dev/null

# Pre-create gif0 so it is immediately available in Interface Assignments
# on first-time setups before service enable/apply.
if ! ifconfig gif0 >/dev/null 2>&1; then
    if ifconfig gif0 create >/dev/null 2>&1; then
        echo "Prepared gif0 for initial Interface Assignment."
    else
        echo "WARNING: Failed to pre-create gif0. You can run: ifconfig gif0 create"
    fi
fi

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo "  1. Log out and back into the OPNsense web UI"
echo "  2. Go to Interfaces > OCN Fixed IP (IPoE)"
echo "  3. Enable OCN Fixed IP (IPoE), set required OCN settings, and click Apply"
echo ""
echo "Prerequisites:"
echo "  - WAN interface IPv6 set to DHCPv6 (IPv4: DHCP or None, depending on your environment)"
echo ""
