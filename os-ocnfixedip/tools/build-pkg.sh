#!/bin/sh

# Build FreeBSD pkg for OCN Fixed IP (IPoE) plugin from local source tree.
# Intended to run on OPNsense / FreeBSD.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SRC_DIR="${PROJECT_ROOT}/src"

PKG_NAME="${PKG_NAME:-os-ocnfixedip}"
PKG_VERSION="${PKG_VERSION:-$(date +%Y.%m.%d)}"
PKG_MAINTAINER="${PKG_MAINTAINER:-you@example.invalid}"
PKG_WWW="${PKG_WWW:-https://github.com/unchained-llc/os-ocnfixedip}"
PKG_ORIGIN="${PKG_ORIGIN:-net/os-ocnfixedip}"

WORK_DIR="${WORK_DIR:-${PROJECT_ROOT}/.pkgbuild}"
STAGE_DIR="${WORK_DIR}/stage"
META_DIR="${WORK_DIR}/meta"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/dist}"

if ! command -v pkg >/dev/null 2>&1; then
    echo "ERROR: pkg command not found. Run this on OPNsense/FreeBSD." >&2
    exit 1
fi

if [ ! -d "${SRC_DIR}/opnsense" ] || [ ! -d "${SRC_DIR}/etc" ]; then
    echo "ERROR: src tree not found at ${SRC_DIR}" >&2
    exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${STAGE_DIR}/usr/local/opnsense" "${STAGE_DIR}/usr/local/etc" "${META_DIR}" "${OUT_DIR}"
mkdir -p "${STAGE_DIR}/usr/local/share/licenses/${PKG_NAME}"
cp "${PROJECT_ROOT}/../LICENSE" "${STAGE_DIR}/usr/local/share/licenses/${PKG_NAME}/LICENSE"

# Stage the plugin files under /usr/local.
tar --exclude '__pycache__' --exclude '*.py[co]' --exclude '.DS_Store' -C "${SRC_DIR}/opnsense" -cf - . | tar -C "${STAGE_DIR}/usr/local/opnsense" -xf -
tar --exclude '__pycache__' --exclude '*.py[co]' --exclude '.DS_Store' -C "${SRC_DIR}/etc" -cf - . | tar -C "${STAGE_DIR}/usr/local/etc" -xf -

if [ -d "${STAGE_DIR}/usr/local/opnsense/scripts/OPNsense/ocnfixedip" ]; then
    find "${STAGE_DIR}/usr/local/opnsense/scripts/OPNsense/ocnfixedip" -type f -name "*.sh" -exec chmod 0555 {} \;
fi

# Build plist from staged files/links.
(
    cd "${STAGE_DIR}"
    find usr/local -type f -o -type l | sort
) > "${META_DIR}/plist"

cat > "${META_DIR}/manifest.ucl" <<EOF
name: "${PKG_NAME}"
version: "${PKG_VERSION}"
origin: "${PKG_ORIGIN}"
comment: "OCN Fixed IP (IPoE) plugin for OPNsense"
maintainer: "${PKG_MAINTAINER}"
www: "${PKG_WWW}"
prefix: "/"
licenses: [ "BSD2CLAUSE" ]
desc: <<EOD
OCN Fixed IP (IPoE) plugin for OPNsense.
Provides tunnel configuration, status, diagnostics, API, and dashboard widget.
EOD
categories: [ "net" ]
scripts: {
  pre-install: <<EOD
#!/bin/sh
for tool in python3 curl xmllint ifconfig route sysctl; do
  if ! command -v "\$tool" >/dev/null 2>&1; then
    echo "Missing runtime prerequisite: \$tool" >&2
    exit 1
  fi
done
python3 -c 'import subprocess, sys; version = subprocess.check_output(["curl", "--version"], text=True).split()[1]; sys.exit(0 if tuple(int(p) for p in version.split(".")[:2]) >= (7, 84) else "curl 7.84+ is required")' || exit 1
EOD
  post-install: <<EOD
#!/bin/sh
# Remove the obsolete plugin-local translation asset on upgrades/reinstalls.
rm -f /usr/local/opnsense/www/js/ocnfixedip/i18n.js
rmdir /usr/local/opnsense/www/js/ocnfixedip >/dev/null 2>&1 || true
service configd restart >/dev/null 2>&1 || true
rm -rf /tmp/opnsense_*cache* >/dev/null 2>&1 || true
if ! ifconfig gif0 >/dev/null 2>&1; then
  ifconfig gif0 create >/dev/null 2>&1 || true
fi
EOD

  pre-deinstall: <<EOD
#!/bin/sh
configctl ocnfixedip stop >/dev/null 2>&1 || true
EOD
  post-deinstall: <<EOD
#!/bin/sh
service configd restart >/dev/null 2>&1 || true
rm -rf /tmp/opnsense_*cache* >/dev/null 2>&1 || true
EOD
}
EOF

pkg create \
    -M "${META_DIR}/manifest.ucl" \
    -r "${STAGE_DIR}" \
    -p "${META_DIR}/plist" \
    -o "${OUT_DIR}"

echo ""
echo "Package output directory: ${OUT_DIR}"
ls -1 "${OUT_DIR}" | sed 's/^/  - /'
