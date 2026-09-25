#!/usr/bin/env bash
# libsodium → $DEPS_PREFIX (PHP ext/sodium).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libsodium "$LIBSODIUM_VERSION" "$LIBSODIUM_URL" "$LIBSODIUM_SHA256"
autotools_build
dep_finish
