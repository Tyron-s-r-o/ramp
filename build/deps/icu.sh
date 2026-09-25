#!/usr/bin/env bash
# ICU4C → $DEPS_PREFIX (intl, used by PHP ext/intl). Install ids are made @rpath by relocate.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start icu "$ICU_VERSION" "$ICU_URL" "$ICU_SHA256"
cd source
run_logged "$DEP" ./runConfigureICU MacOSX --prefix="$DEPS_PREFIX" --libdir="$DEPS_PREFIX/lib" \
  --enable-shared --disable-static --disable-samples --disable-tests --disable-extras
run_logged "$DEP" make -j"$NPROC"
run_logged "$DEP" make install
dep_finish
