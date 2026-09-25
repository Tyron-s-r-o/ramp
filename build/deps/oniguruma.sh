#!/usr/bin/env bash
# oniguruma → $DEPS_PREFIX (PHP mbstring regex).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start onig "$ONIG_VERSION" "$ONIG_URL" "$ONIG_SHA256"
autotools_build
dep_finish
