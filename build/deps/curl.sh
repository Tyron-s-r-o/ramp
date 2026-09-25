#!/usr/bin/env bash
# curl/libcurl → $DEPS_PREFIX against our OpenSSL (TLS behaves like Linux servers, not SecureTransport).
# No compiled-in CA bundle/path: runtime uses SSL_CERT_FILE (tool) / openssl default paths, and PHP
# gets curl.cainfo in php.ini. Disabled: ldap, psl, idn2, brotli, zstd, nghttp2 (HTTP/2), ssh, rtmp.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start curl "$CURL_VERSION" "$CURL_URL" "$CURL_SHA256"
autotools_build --with-openssl="$DEPS_PREFIX" --with-zlib \
  --without-ca-bundle --without-ca-path --without-ca-fallback \
  --without-libpsl --without-libidn2 --without-brotli --without-zstd --without-nghttp2 --without-nghttp3 \
  --without-ngtcp2 --without-libssh2 --without-libssh --without-librtmp --without-gssapi \
  --disable-ldap --disable-ldaps --disable-docs --disable-manual
dep_finish
