#!/bin/sh

# Deploy OCN Virtual Connect Fixed IP plugin to OPNsense
# Usage: ./deploy.sh [opnsense_host]

set -e

OPNSENSE_HOST="${1:-192.168.0.2}"
OPNSENSE_USER="root"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${PLUGIN_DIR}/src"

echo "Deploying OCN Virtual Connect Fixed IP plugin to ${OPNSENSE_HOST}..."

echo "  -> MVC components..."
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "mkdir -p \
    /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL \
    /usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu \
    /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api \
    /usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms \
    /usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP \
    /usr/local/opnsense/scripts/OPNsense/ocnfixedip"

scp -q "${SRC_DIR}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/OCNFixedIP.xml" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/"
scp -q "${SRC_DIR}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/OCNFixedIP.php" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/"
scp -q "${SRC_DIR}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL/ACL.xml" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/ACL/"
scp -q "${SRC_DIR}/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu/Menu.xml" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/models/OPNsense/OCNFixedIP/Menu/"

scp -q "${SRC_DIR}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/GeneralController.php" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/"
scp -q "${SRC_DIR}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/DiagnosticsController.php" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/"
scp -q "${SRC_DIR}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/SettingsController.php" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/"
scp -q "${SRC_DIR}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/ServiceController.php" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/"
scp -q "${SRC_DIR}/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/"

scp -q "${SRC_DIR}/opnsense/mvc/app/views/OPNsense/OCNFixedIP/general.volt" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP/"
scp -q "${SRC_DIR}/opnsense/mvc/app/views/OPNsense/OCNFixedIP/diagnostics.volt" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/mvc/app/views/OPNsense/OCNFixedIP/"

echo "  -> Dashboard widget..."
scp -q "${SRC_DIR}/opnsense/www/js/widgets/OCNFixedIP.js" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/www/js/widgets/"
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "mkdir -p /usr/local/opnsense/www/js/widgets/Metadata"
scp -q "${SRC_DIR}/opnsense/www/js/widgets/Metadata/OCNFixedIP.xml" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/www/js/widgets/Metadata/"

echo "  -> Backend scripts..."
scp -q "${SRC_DIR}/opnsense/scripts/OPNsense/ocnfixedip/"*.sh \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/scripts/OPNsense/ocnfixedip/"
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "chmod +x /usr/local/opnsense/scripts/OPNsense/ocnfixedip/*.sh"

echo "  -> Configd actions..."
scp -q "${SRC_DIR}/opnsense/service/conf/actions.d/actions_ocnfixedip.conf" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/opnsense/service/conf/actions.d/"

echo "  -> Plugin registration..."
scp -q "${SRC_DIR}/etc/inc/plugins.inc.d/ocnfixedip.inc" \
    "${OPNSENSE_USER}@${OPNSENSE_HOST}:/usr/local/etc/inc/plugins.inc.d/"

echo "  -> Removing legacy DSLite leftovers..."
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "rm -rf \
    /usr/local/opnsense/mvc/app/models/OPNsense/DSLite \
    /usr/local/opnsense/mvc/app/controllers/OPNsense/DSLite \
    /usr/local/opnsense/mvc/app/views/OPNsense/DSLite \
    /usr/local/opnsense/scripts/OPNsense/dslite 2>/dev/null; \
    rm -f \
    /usr/local/etc/inc/plugins.inc.d/dslite.inc \
    /usr/local/opnsense/service/conf/actions.d/actions_dslite.conf \
    /usr/local/opnsense/www/js/widgets/DSLite.js \
    /usr/local/opnsense/www/js/widgets/Metadata/DSLite.xml 2>/dev/null; true"

echo "  -> Restarting configd..."
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "service configd restart"

echo "  -> Flushing UI caches..."
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "find /tmp -maxdepth 1 -name 'opnsense_*cache*' -exec rm -rf {} + 2>/dev/null; \
    configctl template reload OPNsense/OCNFixedIP 2>/dev/null; true"

echo "  -> Verifying no legacy prefix-update cron entry..."
ssh "${OPNSENSE_USER}@${OPNSENSE_HOST}" "crontab -l 2>/dev/null | grep -E 'ocnfixedip-prefix-update|OPNsense/ocnfixedip/prefix_update.sh' || true"

echo ""
echo "Deploy complete! Access the plugin at:"
echo "  https://${OPNSENSE_HOST}/ui/ocnfixedip/general"
echo ""
echo "You may need to log out and back in for the menu to appear."
