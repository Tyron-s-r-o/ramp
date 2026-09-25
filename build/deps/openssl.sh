#!/usr/bin/env bash
# OpenSSL (3.5 LTS) → $DEPS_PREFIX, relocatable (@rpath ids), + Mozilla CA bundle.
#
# Runtime note: OPENSSLDIR / MODULESDIR / ENGINESDIR are compiled-in absolute stage paths.
# They are NOT used at runtime — the app must export, per service:
#   SSL_CERT_FILE=<root>/ssl/cert.pem      (CA bundle shipped here)
#   OPENSSL_CONF=<root>/ssl/openssl.cnf
#   OPENSSL_MODULES=<root>/lib/ossl-modules  (only if the legacy provider is needed)
# PHP additionally gets openssl.cafile / curl.cainfo in php.ini (Phase 4).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

name="openssl-$OPENSSL_VERSION"
if is_built "$name"; then log "$name already built (FORCE=1 to rebuild)"; exit 0; fi

tarball="$(fetch openssl "$OPENSSL_URL" "$OPENSSL_SHA256")"
cacert="$(fetch cacert "$CACERT_URL" "$CACERT_SHA256")"
src="$(extract "$tarball")"

log "configure $name → $DEPS_PREFIX"
cd "$src"
run_logged "$name" ./Configure darwin64-arm64-cc shared no-tests no-docs \
  --prefix="$DEPS_PREFIX" --openssldir="$DEPS_PREFIX/ssl" --libdir=lib
log "make -j$NPROC"
run_logged "$name" make -j"$NPROC"
log "install"
run_logged "$name" make install_sw install_ssldirs

install -m 0644 "$cacert" "$DEPS_PREFIX/ssl/cert.pem"

"$RAMP_BUILD/lib/relocate.sh" "$DEPS_PREFIX"
"$RAMP_BUILD/lib/audit.sh" "$DEPS_PREFIX"

"$DEPS_PREFIX/bin/openssl" version | grep -q "OpenSSL $OPENSSL_VERSION" || die "unexpected openssl version"
mark_built "$name"
log "$name done: $("$DEPS_PREFIX/bin/openssl" version)"
