#!/usr/bin/env bash
# FreeType → $DEPS_PREFIX, with png + system zlib/bzip2; no harfbuzz/brotli/librsvg.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start freetype "$FREETYPE_VERSION" "$FREETYPE_URL" "$FREETYPE_SHA256"
autotools_build --with-png=yes --with-zlib=yes --with-bzip2=yes \
  --with-harfbuzz=no --with-brotli=no --with-librsvg=no
dep_finish
