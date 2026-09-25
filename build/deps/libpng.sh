#!/usr/bin/env bash
# libpng → $DEPS_PREFIX (gd, freetype, ImageMagick). zlib from macOS.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libpng "$LIBPNG_VERSION" "$LIBPNG_URL" "$LIBPNG_SHA256"
autotools_build
dep_finish
