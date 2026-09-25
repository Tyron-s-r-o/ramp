#!/usr/bin/env bash
# libxml2 → $DEPS_PREFIX (Apple's system copy is old). zlib/iconv from macOS; no python/lzma/icu.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libxml2 "$LIBXML2_VERSION" "$LIBXML2_URL" "$LIBXML2_SHA256"
autotools_build --without-python --without-lzma --without-icu --without-readline --without-history \
  --with-zlib --with-iconv
dep_finish
