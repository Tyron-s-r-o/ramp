#!/usr/bin/env bash
# build-all.sh [step…] — whole Phase 1 pipeline end to end (plans 01-01 … 01-07).
#
#   build/build-all.sh                    # every step, in order
#   build/build-all.sh package manifest   # only these steps
#   FROM=apache build/build-all.sh        # start at a step
#   FORCE=1 build/build-all.sh            # passed through: rebuild everything
#
# Steps (each underlying script is idempotent — finished work is skipped):
#   toolchain  bootstrap-toolchain.sh            Homebrew build-time tools
#   deps       deps/all.sh                       shared C libs → .stage/deps
#   php8       php/build-all-8x.sh               PHP 8.1–8.5 (+ FPM smoke, audit)
#   php74      php/build-php.sh 7.4              PHP 7.4 (legacy, patched; MAMP 7.3 projects)
#   php73      php/build-php.sh 7.3              PHP 7.3 (legacy, patched)
#   ext        php/build-all-ext.sh              PECL extensions × 8.x → out/ext-matrix.md
#   apache     apache/build-apache.sh + smoke    Apache 2.4 (+ Apache → PHP-FPM smoke)
#   redis      redis/build-redis.sh              Redis (+ smoke)
#   mysql      mysql/fetch-mysql.sh + smoke      official MySQL 9.7 + 8.4 tarballs
#   pma        phpmyadmin/fetch-pma.sh           phpMyAdmin
#   elasticvue elasticvue/fetch-elasticvue.sh    Elasticvue web build (npm, build-time only)
#   package    package.sh                        dist/*.tar.xz
#   manifest   manifest.sh                       dist/manifest.json
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/common.sh"

ALL=(toolchain deps php8 php74 php73 ext apache redis mysql pma elasticvue package manifest)

run_step() {
  case "$1" in
    toolchain) "$here/bootstrap-toolchain.sh" ;;
    deps)      "$here/deps/all.sh" ;;
    php8)      "$here/php/build-all-8x.sh" ;;
    php74)     "$here/php/build-php.sh" 7.4 ;;
    php73)     "$here/php/build-php.sh" 7.3 ;;
    ext)       "$here/php/build-all-ext.sh" ;;
    apache)    "$here/apache/build-apache.sh" && "$here/apache/smoke-apache.sh" ;;
    redis)     "$here/redis/build-redis.sh" ;;
    mysql)     "$here/mysql/fetch-mysql.sh" && "$here/mysql/smoke-mysql.sh" ;;
    pma)       "$here/phpmyadmin/fetch-pma.sh" ;;
    elasticvue) "$here/elasticvue/fetch-elasticvue.sh" ;;
    package)   "$here/package.sh" ;;
    manifest)  "$here/manifest.sh" ;;
    *) die "unknown step '$1' (steps: ${ALL[*]})" ;;
  esac
}

steps=("$@")
if ((${#steps[@]} == 0)); then
  steps=("${ALL[@]}")
  if [[ -n "${FROM:-}" ]]; then
    for i in "${!ALL[@]}"; do [[ "${ALL[$i]}" == "$FROM" ]] && { steps=("${ALL[@]:$i}"); break; }; done
    [[ "${steps[0]}" == "$FROM" ]] || die "unknown FROM step '$FROM'"
  fi
fi

t0=$SECONDS
for s in "${steps[@]}"; do
  ts=$SECONDS
  log "==== step $s"
  run_step "$s" || die "step '$s' failed"
  log "==== step $s done ($((SECONDS - ts))s)"
done
log "build-all: ${steps[*]} OK in $((SECONDS - t0))s"
