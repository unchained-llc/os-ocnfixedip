PKG_NAME ?= os-ocnfixedip
# Leave empty by default; tools/build-pkg.sh will auto-generate a date-only version.
PKG_VERSION ?=
PKG_MAINTAINER ?= you@example.invalid
PKG_WWW ?= https://github.com/unchained-llc/os-ocnfixedip
PKG_ORIGIN ?= net/os-ocnfixedip

.PHONY: pkg clean check

pkg:
	@PKG_NAME="${PKG_NAME}" \
	PKG_VERSION="${PKG_VERSION}" \
	PKG_MAINTAINER="${PKG_MAINTAINER}" \
	PKG_WWW="${PKG_WWW}" \
	PKG_ORIGIN="${PKG_ORIGIN}" \
	sh ./tools/build-pkg.sh

clean:
	rm -rf ./.pkgbuild ./dist

check:
	python3 ./tools/check.py
