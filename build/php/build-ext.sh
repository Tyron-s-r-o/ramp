#!/usr/bin/env bash
# build-ext.sh <php-ver> <ext> — one shared PHP extension for one PHP version.
#
#   build/php/build-ext.sh 8.2 phalcon          # or the full version: 8.2.34
#   FORCE=1 build/php/build-ext.sh 8.3 imagick  # rebuild even if already installed
#   JOBS=4  build/php/build-ext.sh 8.4 redis    # make -j (default $NPROC)
#
# <ext> ∈ redis apcu yaml imagick memcached xdebug phalcon
#
# Source pins come from versions.env: PECL_<EXT>_{VERSION,URL,SHA256} (xdebug/phalcon:
# XDEBUG_*, PHALCON_*). A PHP branch can pin a different release (e.g. for 7.3/7.4) by defining
# PHP<MM>_<PREFIX>_{VERSION,URL,SHA256}, e.g. PHP73_PECL_REDIS_VERSION=5.3.7 — those win.
#
# Pipeline: fetch (sha256) → extract to .stage/work/ext/<phpver>/<ext> → phpize + configure
# with the stage PHP's php-config (.stage/php/<ver>, the prefix PHP was built for) → make →
# assemble a mini tree (<ext_rel>/<ext>.so + lib/ closure from .stage/deps) → relocate + audit
# → copy new dylibs into out/php/<ver>/lib, .so into out/php/<ver>/<extension_dir_rel>/
# (tmp + mv, so concurrent builds for the same PHP version never touch each other's files).
#
# Extensions are NOT enabled anywhere — the app writes conf.d ini files (Phase 4).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"

arg="${1:?usage: build-ext.sh <php-ver> <ext>}"
ext="${2:?usage: build-ext.sh <php-ver> <ext>}"
IFS=. read -r maj min _ <<<"$arg"
mm="${maj}${min}"
vvar="PHP${mm}_VERSION"
phpver="${!vvar:-}"
[[ -n "$phpver" ]] || die "no $vvar in versions.env"
[[ "$arg" == "$maj.$min" || "$arg" == "$phpver" ]] || die "requested $arg but versions.env pins $phpver"

stage_php="$STAGE_DIR/php/$phpver"
out_php="$OUT_DIR/php/$phpver"
[[ -x "$stage_php/bin/phpize" && -x "$stage_php/bin/php-config" ]] || die "no stage PHP at $stage_php (build PHP $phpver first)"
[[ -f "$out_php/ramp.json" ]] || die "no out tree $out_php/ramp.json"
ext_rel="$(sed -n 's/.*"extension_dir_rel": "\(.*\)".*/\1/p' "$out_php/ramp.json")"
[[ -n "$ext_rel" ]] || die "extension_dir_rel missing in $out_php/ramp.json"

# ------------------------------------------------------------------ per-extension recipe
SDK="$(xcrun --show-sdk-path)"
zend=0 conf=()
case "$ext" in
  redis)     pin=PECL_REDIS;     conf=(--enable-redis --enable-redis-igbinary=no --enable-redis-msgpack=no
                                       --enable-redis-lzf=no --enable-redis-zstd=no --enable-redis-lz4=no) ;;
  apcu)      pin=PECL_APCU;      conf=(--enable-apcu) ;;
  yaml)      pin=PECL_YAML;      conf=(--with-yaml="$DEPS_PREFIX") ;;
  imagick)   pin=PECL_IMAGICK;   conf=(--with-imagick="$DEPS_PREFIX") ;;
  memcached) pin=PECL_MEMCACHED; conf=(--enable-memcached --with-libmemcached-dir="$DEPS_PREFIX"
                                       --with-zlib-dir="$SDK/usr" --disable-memcached-sasl
                                       --enable-memcached-session --disable-memcached-igbinary
                                       --disable-memcached-msgpack --disable-memcached-json) ;;
  xdebug)    pin=XDEBUG;         conf=(--enable-xdebug); zend=1 ;;
  phalcon)   pin=PHALCON;        conf=(--enable-phalcon) ;;
  *) die "unknown extension '$ext' (redis apcu yaml imagick memcached xdebug phalcon)" ;;
esac
# branch-specific pin (PHP73_PECL_REDIS_VERSION …) overrides the generic one
for f in VERSION URL SHA256; do
  o="PHP${mm}_${pin}_$f" g="${pin}_$f"
  printf -v "E_$f" '%s' "${!o:-${!g:-}}"
done
[[ -n "$E_VERSION" && -n "$E_URL" ]] || die "no ${pin}_VERSION/URL in versions.env"

name="ext-$ext-$E_VERSION-php-$phpver"
so_dst="$out_php/$ext_rel/$ext.so"
if is_built "$name" && [[ -f "$so_dst" ]]; then
  log "$name already built → $so_dst (FORCE=1 to rebuild)"; exit 0
fi

JOBS="${JOBS:-$NPROC}"
lf="$LOG_DIR/$name.log"
: >"$lf"

# ------------------------------------------------------------------ fetch + extract
tarball="$(fetch "$ext" "$E_URL" "$E_SHA256")"
work="$WORK_DIR/ext/$phpver/$ext"
rm -rf "$work"; mkdir -p "$work"
tar -xf "$tarball" -C "$work"
# PECL tarballs: package.xml + <name>-<ver>/ — build dir is the one holding config.m4
src="$(find "$work" -maxdepth 2 -name config.m4 -print -quit)"
[[ -n "$src" ]] || die "no config.m4 in $tarball"
src="$(dirname "$src")"
cd "$src"

# ------------------------------------------------------------------ build
# Xcode 16+ clang promotes these to errors; older extension releases still trip them
export CFLAGS="$CFLAGS -Wno-incompatible-function-pointer-types -Wno-implicit-function-declaration"
# PHP 7.x headers/older ext releases are not C23-clean (K&R `f()` = no args); autoconf >= 2.72
# makes CC "clang -std=gnu23", a later -std in CFLAGS wins (same flag the 7.3 core is built with)
((maj < 8)) && export CFLAGS="$CFLAGS -std=gnu17"
log "build $name (log: $lf)"
run_logged "$name" "$stage_php/bin/phpize"
run_logged "$name" ./configure --with-php-config="$stage_php/bin/php-config" "${conf[@]}"
run_logged "$name" make -j"$JOBS"
[[ -f "modules/$ext.so" ]] || die "make produced no modules/$ext.so"

# ------------------------------------------------------------------ relocate + audit in a mini tree
mini="$work/_tree"
rm -rf "$mini"; mkdir -p "$mini/lib" "$mini/$ext_rel"
cp "modules/$ext.so" "$mini/$ext_rel/$ext.so"
# @rpath closure from .stage/deps (skip what the PHP tree already ships)
added=1
while ((added)); do
  added=0
  while IFS= read -r -d '' f; do
    while IFS= read -r d; do
      base="${d#@rpath/}"
      [[ -e "$mini/lib/$base" ]] && continue
      [[ -e "$DEPS_PREFIX/lib/$base" ]] || die "$f needs $d, not in $DEPS_PREFIX/lib"
      cp -L "$DEPS_PREFIX/lib/$base" "$mini/lib/$base"; chmod u+w "$mini/lib/$base"
      added=1
    done < <(otool -L "$f" | tail -n +2 | awk '$1 ~ /^@rpath\// {print $1}')
  done < <(find "$mini" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)
done
run_logged "$name" "$RAMP_BUILD/lib/relocate.sh" "$mini"
if ! audit_out="$("$RAMP_BUILD/lib/audit.sh" "$mini" 2>&1)"; then
  printf '%s\n' "$audit_out" | grep '✗' | head -40 >&2
  die "audit failed for $name"
fi
printf '%s\n' "$audit_out" | grep '^  !' >>"$lf" || true
[[ "$(lipo -archs "$mini/$ext_rel/$ext.so")" == arm64 ]] || die "$ext.so is not arm64-only"

# ------------------------------------------------------------------ install into out tree
mkdir -p "$out_php/$ext_rel"
for f in "$mini"/lib/*; do
  [[ -e "$f" ]] || continue
  b="$(basename "$f")"
  [[ -e "$out_php/lib/$b" ]] && continue
  cp -p "$f" "$out_php/lib/.$b.$$" && mv -f "$out_php/lib/.$b.$$" "$out_php/lib/$b"
  log "$name: bundled lib/$b"
done
cp -p "$mini/$ext_rel/$ext.so" "$so_dst.$$" && mv -f "$so_dst.$$" "$so_dst"

# ------------------------------------------------------------------ load test (stage-independent: -n)
php=("$out_php/bin/php" -n -d "extension_dir=$out_php/$ext_rel")
if ((zend)); then load=(-d "zend_extension=$ext"); else load=(-d "extension=$ext"); fi
"${php[@]}" "${load[@]}" -r "exit(extension_loaded('$ext') ? 0 : 1);" >>"$lf" 2>&1 \
  || { tail -5 "$lf" >&2; die "$ext.so does not load into PHP $phpver"; }

mark_built "$name"
printf '%s\t%s\t%s\t%s\n' "$phpver" "$ext" "$E_VERSION" "$(( zend ? 1 : 0 ))" >"$STAGE_DIR/.built/$name"
log "$name done → $so_dst"
