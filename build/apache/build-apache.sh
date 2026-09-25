#!/usr/bin/env bash
# build-apache.sh — Apache httpd (event MPM, all modules shared) with bundled APR/apr-util
# (srclib, --with-included-apr), PCRE2 + OpenSSL + libxml2 from the shared deps prefix.
#
# Output: out/apache/<ver>/{bin,modules,lib,conf/{mime.types,magic},error,icons,include,build}
#   lib/ = libapr-1, libaprutil-1 + copied deps dylibs (libpcre2-8, libssl, libcrypto, libxml2)
#   No httpd.conf is shipped — the app generates its own. Run:  bin/httpd -d <ServerRoot> -f <conf>
#   (modules via `LoadModule x modules/mod_x.so`, relative to ServerRoot).
#   Compiled-in HTTPD_ROOT / apxs / apachectl / envvars point to the build stage — never used at runtime.
#
# Requires: build/deps/openssl.sh, build/deps/pcre2.sh, build/deps/libxml2.sh (or deps/all.sh).
# FORCE=1 rebuilds.  Smoke test: build/apache/smoke-apache.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ver="$HTTPD_VERSION"
stage="$STAGE_DIR/apache/$ver"
out="$OUT_DIR/apache/$ver"

if is_built "httpd-$ver" && [[ -x "$out/bin/httpd" ]]; then
  log "httpd $ver already built ($out) — FORCE=1 to rebuild"; exit 0
fi

for f in "$DEPS_PREFIX/bin/pcre2-config" "$DEPS_PREFIX/lib/libssl.3.dylib" "$DEPS_PREFIX/include/libxml2/libxml/parser.h"; do
  [[ -e "$f" ]] || die "missing dep $f — run build/deps/all.sh (pcre2, openssl, libxml2)"
done

httpd_tb="$(fetch httpd "$HTTPD_URL" "$HTTPD_SHA256")"
apr_tb="$(fetch apr "$APR_URL" "$APR_SHA256")"
aprutil_tb="$(fetch apr-util "$APR_UTIL_URL" "$APR_UTIL_SHA256")"
src="$(extract "$httpd_tb")"
apr_src="$(extract "$apr_tb" "$src/srclib")";         mv "$apr_src" "$src/srclib/apr"
aprutil_src="$(extract "$aprutil_tb" "$src/srclib")"; mv "$aprutil_src" "$src/srclib/apr-util"

step="httpd-$ver"
: >"$LOG_DIR/$step.log"
log "build $step (-j$NPROC, log: $LOG_DIR/$step.log)"
cd "$src"
rm -rf "$stage"
# apr-util: expat from the macOS SDK; no DBD/DBM/LDAP drivers (nothing in RAMP uses them).
# zlib (mod_deflate) = system libz via SDK. Disabled (deps not pinned): brotli, http2/proxy_http2
# (nghttp2), md (jansson), lua.
run_logged "$step" ./configure --prefix="$stage" \
  --with-included-apr \
  --with-pcre="$DEPS_PREFIX/bin/pcre2-config" \
  --enable-ssl --with-ssl="$DEPS_PREFIX" \
  --with-libxml2="$DEPS_PREFIX/include/libxml2" \
  --with-mpm=event --enable-mpms-shared=all \
  --enable-mods-shared=reallyall \
  --enable-so --enable-proxy --enable-proxy-fcgi --enable-rewrite --enable-headers \
  --without-sqlite3 --without-pgsql --without-mysql --without-odbc --without-oracle \
  --without-berkeley-db --without-gdbm --without-ndbm --without-lmdb --without-ldap \
  --without-crypto \
  --with-z="$(xcrun --show-sdk-path)/usr" \
  --disable-brotli --disable-http2 --disable-proxy-http2 --disable-md --disable-lua
run_logged "$step" make -j"$NPROC"
run_logged "$step" make install

# ---------------------------------------------------------------- stage → out
rm -rf "$out"; mkdir -p "$out/conf"
for d in bin modules lib include build error icons; do cp -R "$stage/$d" "$out/$d"; done
cp "$stage/conf/mime.types" "$stage/conf/magic" "$out/conf/"
mkdir -p "$out/logs"
# static archives / libtool files / pkgconfig are build-time only
find "$out/lib" \( -name '*.a' -o -name '*.la' -o -name '*.exp' \) -delete
rm -rf "$out/lib/pkgconfig"

# copy the @rpath deps closure from $DEPS_PREFIX/lib into out/lib
copied=0
while :; do
  added=0
  while IFS= read -r -d '' f; do
    [[ "$(file -b "$f")" == Mach-O* ]] || continue
    while IFS= read -r dep; do
      base="${dep#@rpath/}"
      [[ -e "$out/lib/$base" ]] && continue
      [[ -e "$DEPS_PREFIX/lib/$base" ]] || die "$f needs $dep — not in $out/lib nor $DEPS_PREFIX/lib"
      cp -L "$DEPS_PREFIX/lib/$base" "$out/lib/$base"; chmod u+w "$out/lib/$base"
      log "bundled deps lib/$base"; added=$((added+1)); copied=$((copied+1))
    done < <(otool -L "$f" | tail -n +2 | awk '$1 ~ /^@rpath\//{print $1}')
  done < <(find "$out/bin" "$out/modules" "$out/lib" -type f -print0)
  ((added)) || break
done
log "deps copied: $copied"

bash "$RAMP_BUILD/lib/relocate.sh" "$out"
bash "$RAMP_BUILD/lib/audit.sh" "$out"
if find "$out/bin" "$out/modules" "$out/lib" -type f -exec otool -L {} + 2>/dev/null | grep -E '/opt/homebrew|/usr/local'; then
  die "httpd links Homebrew/local libs"
fi

"$out/bin/httpd" -V | grep -q "Server version: Apache/$ver" || die "httpd -V: unexpected version"
mark_built "httpd-$ver"
log "httpd $ver done → $out ($(ls "$out/modules" | wc -l | tr -d ' ') modules)"
