#!/usr/bin/env bash
# PCRE2 → $DEPS_PREFIX (8-bit lib only + JIT) — used by Apache httpd (PHP keeps its bundled pcre2).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start pcre2 "$PCRE2_VERSION" "$PCRE2_URL" "$PCRE2_SHA256"
autotools_build --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --enable-jit \
  --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libedit --disable-pcre2test-libreadline
dep_finish
