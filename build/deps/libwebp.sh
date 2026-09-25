#!/usr/bin/env bash
# libwebp (+mux/demux/sharpyuv) → $DEPS_PREFIX; cwebp/dwebp tools use our png/jpeg.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libwebp "$LIBWEBP_VERSION" "$LIBWEBP_URL" "$LIBWEBP_SHA256"
autotools_build --enable-libwebpmux --enable-libwebpdemux --enable-libwebpdecoder \
  --disable-gif --disable-tiff --disable-gl --disable-sdl --disable-wic
dep_finish
