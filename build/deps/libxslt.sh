#!/usr/bin/env bash
# libxslt (+libexslt) → $DEPS_PREFIX, against our libxml2. No python, no libgcrypt.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libxslt "$LIBXSLT_VERSION" "$LIBXSLT_URL" "$LIBXSLT_SHA256"
autotools_build --without-python --without-crypto --with-libxml-prefix="$DEPS_PREFIX"
dep_finish
