#!/usr/bin/env bash
# build-php.sh <version>  — PHP 8.x / 7.4 / 7.3 (FPM + CLI) → build/out/php/<version>/, relocatable.
#
#   build/php/build-php.sh 8.3.35        # or just "8.3" (version taken from versions.env)
#   FORCE=1 build/php/build-php.sh 8.3   # rebuild even if out/php/<ver> exists
#   JOBS=7 build/php/build-php.sh 8.4    # make -j (default $NPROC); build-all-8x.sh sets it
#
# Version hook: patches/<major.minor>/*.patch are applied in order (patch -p1) right after
# extraction; if any of them touches an *.m4 file, ./buildconf --force regenerates configure.
# 7.3 additionally gets its own configure option set + -std=gnu17 / -lresolv (see below);
# 7.4 uses the 8.x (pkg-config) option set + external PCRE2 + -std=gnu17 / -lresolv.
#
# Pipeline: fetch (sha256) → [patch + buildconf] → configure against .stage/deps → make → make install into
# .stage/php/<ver> → copy to out/php/.<ver>.tmp → bundle @rpath dep dylibs into lib/ →
# relocate + audit → self-test (moved tree) → atomic mv to out/php/<ver> → ramp.json.
#
# The out tree appears only when complete (parallel consumers such as the Apache smoke test
# may use out/php/<ver> while other versions build).
#
# Runtime contract: always launch with `-c <php.ini>` / PHPRC and an ABSOLUTE extension_dir
# (compiled-in paths point to the build stage). The extension subdir name is recorded in
# out/php/<ver>/ramp.json as extension_dir_rel.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"

arg="${1:?usage: build-php.sh <8.x[.y]|7.4[.y]|7.3[.y]>}"
IFS=. read -r maj min _ <<<"$arg"
key="PHP${maj}${min}"
vvar="${key}_VERSION" uvar="${key}_URL" svar="${key}_SHA256"
ver="${!vvar:-}"
[[ -n "$ver" ]] || die "no $vvar in versions.env"
[[ "$arg" == "$maj.$min" || "$arg" == "$ver" ]] || die "requested $arg but versions.env pins $ver"
[[ "$maj" == 8 || "$maj.$min" == 7.3 || "$maj.$min" == 7.4 ]] || die "build-php.sh handles 8.x, 7.4 and 7.3 only"

name="php-$ver"
out="$OUT_DIR/php/$ver"
if is_built "$name" && [[ -x "$out/bin/php" ]]; then
  log "$name already built → $out (FORCE=1 to rebuild)"; exit 0
fi

JOBS="${JOBS:-$NPROC}"
SDK="$(xcrun --show-sdk-path)"
prefix="$STAGE_DIR/php/$ver"
lf="$LOG_DIR/$name.log"
: >"$lf"

tarball="$(fetch php "${!uvar}" "${!svar}")"
src="$(extract "$tarball")"
cd "$src"

# ------------------------------------------------------------------ version hook: patches
patch_dir="$here/patches/$maj.$min"
if compgen -G "$patch_dir/*.patch" >/dev/null; then
  need_buildconf=0
  for p in "$patch_dir"/*.patch; do
    log "patch $name ← ${p##*/}"
    run_logged "$name" patch -p1 --forward --input="$p"
    if grep -q '^+++ .*\.m4$' "$p"; then need_buildconf=1; fi
  done
  if ((need_buildconf)); then
    log "buildconf --force $name"
    run_logged "$name" ./buildconf --force
  fi
fi

# ------------------------------------------------------------------ configure
# Extension set is identical for every 8.x (see 01-03-PLAN). Everything static except opcache
# (always a shared zend_extension up to 8.4; compiled in unconditionally from 8.5).
if [[ "$maj" == 8 || "$maj.$min" == 7.4 ]]; then
conf=(
  --prefix="$prefix"
  --with-config-file-path="$prefix/etc"
  --with-config-file-scan-dir="$prefix/etc/conf.d"
  --enable-cli --enable-fpm --disable-cgi --disable-phpdbg
  --without-pear
  --enable-bcmath
  --with-bz2="$SDK/usr"
  --enable-calendar
  --with-curl
  --enable-exif
  --enable-ftp
  --enable-gd --with-freetype --with-jpeg --with-webp
  --with-gmp="$DEPS_PREFIX"
  --with-iconv="$SDK/usr"
  --enable-intl
  --enable-mbstring
  --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
  --enable-pcntl
  --with-pdo-sqlite --with-sqlite3
  --enable-soap
  --enable-sockets
  --with-sodium
  --with-xsl
  --with-zip
  --with-zlib
  --with-openssl
  --with-libedit
)

# 8.5+: opcache is always compiled in and the option no longer exists
((maj == 7 || min < 5)) && conf+=(--enable-opcache)
if [[ "$maj" == 7 ]]; then
  # 7.4: same option names as 8.x. External PCRE2 10.48 (bundled 10.34 JIT unreliable on Apple
  # Silicon, as on 7.3). PHP 7.x is not C23-clean; clang >= 15 no longer links res_* implicitly
  # (shivammathur php@7.4: -std=gnu17, -lresolv).
  conf+=(--with-external-pcre)
  export CFLAGS="$CFLAGS -std=gnu17"
  export LDFLAGS="$LDFLAGS -lresolv"
fi
else
# 7.3: same extension set, pre-7.4 option names (explicit dirs, no pkg-config for most libs).
# Bundled libgd; external PCRE2 10.48 (the bundled 10.32 JIT is broken on Apple Silicon, php bug
# #77260); bundled oniguruma + no ffi (n/a in 7.3). json is always built in on 7.3.
conf=(
  --prefix="$prefix"
  --with-config-file-path="$prefix/etc"
  --with-config-file-scan-dir="$prefix/etc/conf.d"
  --enable-cli --enable-fpm --disable-cgi --disable-phpdbg
  --without-pear
  --enable-bcmath
  --with-bz2="$SDK/usr"
  --enable-calendar
  --with-curl="$DEPS_PREFIX"
  --enable-exif
  --enable-ftp
  --with-gd --with-freetype-dir="$DEPS_PREFIX" --with-jpeg-dir="$DEPS_PREFIX"
  --with-png-dir="$DEPS_PREFIX" --with-webp-dir="$DEPS_PREFIX" --with-zlib-dir="$SDK/usr"
  --with-gmp="$DEPS_PREFIX"
  --with-iconv="$SDK/usr"
  --enable-intl --with-icu-dir="$DEPS_PREFIX"
  --enable-mbstring
  --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
  --enable-pcntl
  --with-pdo-sqlite="$DEPS_PREFIX" --with-sqlite3="$DEPS_PREFIX"
  --enable-soap
  --enable-sockets
  --with-sodium="$DEPS_PREFIX"
  --with-libxml-dir="$DEPS_PREFIX"
  --with-xsl="$DEPS_PREFIX"
  --enable-zip --with-libzip="$DEPS_PREFIX"
  --with-zlib="$SDK/usr"
  --with-openssl="$DEPS_PREFIX"
  --with-pcre-regex="$DEPS_PREFIX"
  --with-libedit="$SDK/usr"
  --enable-opcache
)
# PHP 7.x is not C23-clean; clang >= 15 no longer links res_* implicitly (shivammathur php@7.3)
export CFLAGS="$CFLAGS -std=gnu17"
export LDFLAGS="$LDFLAGS -lresolv"
fi

# ICU >= 75 headers require C++17 (older PHP intl config.m4 asks for C++11)
export CXXFLAGS="$CXXFLAGS -std=c++17"
# Xcode 16+ clang promotes these to errors; older PHP branches still trip them
export CFLAGS="$CFLAGS -Wno-incompatible-function-pointer-types -Wno-implicit-function-declaration"

log "configure $name (log: $lf)"
rm -rf "$prefix"
run_logged "$name" ./configure "${conf[@]}"
log "make -j$JOBS $name"
run_logged "$name" make -j"$JOBS"
log "install $name → $prefix"
run_logged "$name" make install
mkdir -p "$prefix/etc/conf.d" "$prefix/var/log" "$prefix/var/run"

# ------------------------------------------------------------------ assemble relocatable tree
tmp="$OUT_DIR/php/.$ver.tmp"
rm -rf "$tmp"; mkdir -p "$OUT_DIR/php"
cp -R "$prefix" "$tmp"
mkdir -p "$tmp/lib"

# bundle the @rpath closure from .stage/deps/lib (dep ids are already @rpath/<soname>)
bundle_deps() {
  local root="$1" added=1 f d base
  while ((added)); do
    added=0
    while IFS= read -r -d '' f; do
      [[ "$(file -b "$f")" == Mach-O* ]] || continue
      while IFS= read -r d; do
        base="${d#@rpath/}"
        [[ -e "$root/lib/$base" ]] && continue
        [[ -e "$DEPS_PREFIX/lib/$base" ]] || die "$f needs $d, not in $DEPS_PREFIX/lib"
        cp -L "$DEPS_PREFIX/lib/$base" "$root/lib/$base"; chmod u+w "$root/lib/$base"
        added=1
      done < <(otool -L "$f" | tail -n +2 | awk '$1 ~ /^@rpath\// {print $1}')
    done < <(find "$root/bin" "$root/sbin" "$root/lib" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
  done
}
bundle_deps "$tmp"
run_logged "$name" "$RAMP_BUILD/lib/relocate.sh" "$tmp"
if ! audit_out="$("$RAMP_BUILD/lib/audit.sh" "$tmp" 2>&1)"; then
  printf '%s\n' "$audit_out" | grep '✗' | head -40 >&2
  die "audit failed for $name"
fi
log "$(printf '%s\n' "$audit_out" | tail -1)"

# ------------------------------------------------------------------ ramp.json
api="$(awk '/#define ZEND_MODULE_API_NO/{print $3}' "$tmp/include/php/Zend/zend_modules.h")"
[[ -n "$api" ]] || die "cannot read ZEND_MODULE_API_NO"
ext_rel="lib/php/extensions/no-debug-non-zts-$api"
mkdir -p "$tmp/$ext_rel"
if [[ -f "$tmp/$ext_rel/opcache.so" ]]; then opcache=shared; else opcache=static; fi
cat >"$tmp/ramp.json" <<JSON
{
  "component": "php",
  "version": "$ver",
  "api": $api,
  "extension_dir_rel": "$ext_rel",
  "opcache": "$opcache",
  "sapis": ["cli", "fpm"]
}
JSON

# ------------------------------------------------------------------ self-test on the moved tree
"$here/verify-php.sh" "$tmp" "$ver" || die "self-test failed for $name"

rm -rf "$out"
mv "$tmp" "$out"
mark_built "$name"
log "$name done → $out"
