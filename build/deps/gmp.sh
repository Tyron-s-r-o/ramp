#!/usr/bin/env bash
# GMP → $DEPS_PREFIX (PHP ext/gmp). C only. Set GMP_DISABLE_ASM=1 if the arm64 asm path breaks.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start gmp "$GMP_VERSION" "$GMP_URL" "$GMP_SHA256"
extra=()
[[ "${GMP_DISABLE_ASM:-0}" == 1 ]] && extra+=(--disable-assembly)
autotools_build --enable-cxx=no ${extra[@]+"${extra[@]}"}
dep_finish
