#!/bin/sh

# OPNsense OCN Virtual Connect Fixed IP Plugin Installer
# Works over IPv6-only connections (for pre-tunnel install)
# Run this directly on the OPNsense box:
#   fetch --no-verify-hostname --no-verify-peer -o /tmp/install-ocnfixedip.sh "https://raw.githubusercontent.com/unchained-llc/os-ocnfixedip/main/os-ocnfixedip/install.sh" && sh /tmp/install-ocnfixedip.sh

set -e

PLUGIN_URL="https://github.com/unchained-llc/os-ocnfixedip/archive/refs/heads/main.tar.gz"
TMP_DIR="/tmp/ocnfixedip-install"

echo "=== OPNsense OCN Virtual Connect Fixed IP Plugin Installer ==="
echo ""

if [ ! -f /usr/local/etc/inc/plugins.inc.d/pf.inc ]; then
    echo "ERROR: This script must be run on an OPNsense system."
    exit 1
fi

echo "Downloading plugin..."
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

if command -v curl >/dev/null 2>&1; then
    curl -6 -skL -o "${TMP_DIR}/plugin.tar.gz" "${PLUGIN_URL}"
elif command -v fetch >/dev/null 2>&1; then
    fetch --no-verify-hostname --no-verify-peer -o "${TMP_DIR}/plugin.tar.gz" "${PLUGIN_URL}"
else
    echo "ERROR: No download tool available (curl or fetch required)"
    exit 1
fi

echo "Extracting..."
tar -xzf "${TMP_DIR}/plugin.tar.gz" -C "${TMP_DIR}" --strip-components=3

if [ ! -f "${TMP_DIR}/opnsense/service/conf/actions.d/actions_ocnfixedip.conf" ]; then
    echo "ERROR: Unexpected archive layout; required plugin files not found."
    exit 1
fi

echo "Installing plugin files..."
SRC="${TMP_DIR}"

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

echo "Restarting configd..."
service configd restart

rm -rf /tmp/opnsense_*cache* 2>/dev/null
rm -rf "${TMP_DIR}"

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo "  1. Log out and back into the OPNsense web UI"
echo "  2. Go to Interfaces > OCN Virtual Connect Fixed IP"
echo "  3. Enable OCN Virtual Connect Fixed IP, set required OCN settings, and click Apply"
echo ""
echo "Prerequisites:"
echo "  - WAN interface set to DHCPv6 (IPv4: None)"
echo ""
