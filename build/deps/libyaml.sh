#!/usr/bin/env bash
# libyaml → $DEPS_PREFIX (PECL yaml).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start yaml "$LIBYAML_VERSION" "$LIBYAML_URL" "$LIBYAML_SHA256"
autotools_build
dep_finish
