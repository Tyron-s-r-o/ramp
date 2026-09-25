#!/usr/bin/env bash
# Build every shared C dependency into $DEPS_PREFIX (build/.stage/deps).
#
# Libraries of one dependency level build concurrently (each with make -j$NPROC); relocate +
# audit run once after every level (RAMP_DEFER_RELOCATE=1 keeps the per-lib scripts from racing
# on install_name_tool/codesign). Per-lib output: $LOG_DIR/<lib>.out (driver) + <name-ver>.log.
#
#   build/deps/all.sh                 # incremental (skips libs with .built markers)
#   FORCE=1 build/deps/all.sh         # rebuild everything
#   RAMP_STAGE_DIR=/tmp/x build/deps/all.sh   # clean-room build into another stage dir
#   ONLY="curl sqlite" build/deps/all.sh      # subset (still level-ordered)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

LEVELS=(
  "openssl"
  "icu libxml2 oniguruma libzip libsodium gmp sqlite curl libpng libjpeg-turbo libyaml libmemcached pcre2"
  "libxslt freetype libwebp"
  "imagemagick"
)

want() { [[ -z "${ONLY:-}" || " $ONLY " == *" $1 "* ]]; }

export RAMP_DEFER_RELOCATE=1
t0=$SECONDS
for level in "${LEVELS[@]}"; do
  pids=() names=()
  for lib in $level; do
    want "$lib" || continue
    "$here/$lib.sh" >"$LOG_DIR/$lib.out" 2>&1 &
    pids+=($!); names+=("$lib")
  done
  ((${#pids[@]})) || continue
  log "level: ${names[*]}"
  failed=()
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || failed+=("${names[$i]}")
  done
  if ((${#failed[@]})); then
    for lib in "${failed[@]}"; do
      printf '\n==== %s FAILED — tail of %s\n' "$lib" "$LOG_DIR/$lib.out" >&2
      tail -n 30 "$LOG_DIR/$lib.out" >&2
    done
    die "failed: ${failed[*]}"
  fi
  deps_relocate_audit
done

log "all deps done in $((SECONDS - t0))s → $DEPS_PREFIX"
