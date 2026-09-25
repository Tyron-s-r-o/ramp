#!/usr/bin/env bash
# build-all-8x.sh [minor…] — build several PHP 8.x versions concurrently, then FPM-smoke each.
#
#   build/php/build-all-8x.sh                 # 8.1 8.2 8.3 8.4 8.5 (finished ones are skipped)
#   build/php/build-all-8x.sh 8.4 8.5         # subset
#   JOBS=7 FORCE=1 build/php/build-all-8x.sh  # make -j per build (default NPROC/2)
#
# Every version has its own source dir (.stage/work/php-<ver>), stage prefix (.stage/php/<ver>),
# temp out dir and log: .stage/logs/php-<ver>.out (driver) + php-<ver>.log (configure/make).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"

minors=("$@")
((${#minors[@]})) || minors=(8.1 8.2 8.3 8.4 8.5)
export JOBS="${JOBS:-$(( NPROC / 2 > 2 ? NPROC / 2 : 2 ))}"

t0=$SECONDS
pids=() vers=()
for m in "${minors[@]}"; do
  vvar="PHP${m/./}_VERSION"; ver="${!vvar:?no $vvar in versions.env}"
  "$here/build-php.sh" "$ver" >"$LOG_DIR/php-$ver.out" 2>&1 &
  pids+=($!); vers+=("$ver")
done
log "building ${vers[*]} concurrently (make -j$JOBS each)"

failed=()
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then log "php-${vers[$i]} built"; else failed+=("${vers[$i]}"); fi
done
for v in ${failed[@]+"${failed[@]}"}; do
  printf '\n==== php-%s FAILED — tail of %s\n' "$v" "$LOG_DIR/php-$v.out" >&2
  tail -n 30 "$LOG_DIR/php-$v.out" >&2
done
((${#failed[@]} == 0)) || die "failed: ${failed[*]}"

for v in "${vers[@]}"; do
  "$here/smoke-fpm.sh" "$v"
  "$RAMP_BUILD/lib/audit.sh" "$OUT_DIR/php/$v" | tail -1
done
log "PHP ${vers[*]} done in $((SECONDS - t0))s"
