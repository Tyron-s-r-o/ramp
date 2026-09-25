#!/usr/bin/env bash
# libjpeg-turbo (cmake) → $DEPS_PREFIX (libjpeg.62 ABI + libturbojpeg).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libjpeg-turbo "$LIBJPEG_TURBO_VERSION" "$LIBJPEG_TURBO_URL" "$LIBJPEG_TURBO_SHA256"
cmake_build -DENABLE_STATIC=OFF -DENABLE_SHARED=ON -DWITH_TURBOJPEG=ON
dep_finish
