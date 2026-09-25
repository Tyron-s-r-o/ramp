#!/usr/bin/env bash
# smoke-apache.sh — Apache → PHP-FPM chain from MOVED copies (tmp dir), no system/MAMP config.
#
#   build/apache/smoke-apache.sh
#   PHP_VER=8.4.26 build/apache/smoke-apache.sh
#   NO_FPM=1 build/apache/smoke-apache.sh      # static file + httpd -M only (PHP not built yet)
#   SMOKE_PORT=18080 (default)
#   APACHE_ROOT=<tree> PHP_ROOT=<tree> PHP_VER=<its version>   # smoke extracted/signed package trees
#
# Checks: httpd -V (event MPM) · httpd -M lists proxy_fcgi/rewrite/headers · static file ·
#         .php via proxy:unix → fpm (PHP_SAPI=fpm-fcgi) · RewriteRule · Header · `Listen 80` as
#         non-root (skipped when :80 is taken, e.g. by MAMP).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

aver="$HTTPD_VERSION"
pver="${PHP_VER:-$PHP83_VERSION}"
port="${SMOKE_PORT:-18080}"
asrc="${APACHE_ROOT:-$OUT_DIR/apache/$aver}"   # APACHE_ROOT/PHP_ROOT: smoke an extracted (e.g. signed) package tree
psrc="${PHP_ROOT:-$OUT_DIR/php/$pver}"
[[ -x "$asrc/bin/httpd" ]] || die "no $asrc — run build/apache/build-apache.sh"
use_fpm=1
if [[ "${NO_FPM:-0}" == 1 ]]; then use_fpm=0
elif [[ ! -x "$psrc/sbin/php-fpm" ]]; then die "no $psrc/sbin/php-fpm (NO_FPM=1 for static-only smoke)"; fi

# short base dir: unix socket paths are limited to 104 bytes
tmp="$(mktemp -d /tmp/ramp-ap.XXXXXX)"
hpid="" fpid=""
cleanup() {
  [[ -n "$hpid" ]] && kill "$hpid" 2>/dev/null || true
  [[ -n "$fpid" ]] && kill "$fpid" 2>/dev/null || true
  wait 2>/dev/null || true
  [[ "${KEEP:-0}" == 1 ]] || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "---- error.log"; cat "$tmp/error.log" 2>/dev/null; echo "---- fpm.log"; cat "$tmp/fpm.log" 2>/dev/null; die "$*"; }

cp -R "$asrc" "$tmp/apache"
mkdir -p "$tmp/www" "$tmp/run"
ap="$tmp/apache"
echo "static-ok" >"$tmp/www/index.html"
cat >"$tmp/www/test.php" <<'PHP'
<?php echo "php=", PHP_VERSION, " sapi=", PHP_SAPI, " server=", $_SERVER['SERVER_SOFTWARE'] ?? '?', " uri=", $_SERVER['REQUEST_URI'], "\n";
PHP

# ---------------------------------------------------------------- php-fpm (moved copy)
if ((use_fpm)); then
  cp -R "$psrc" "$tmp/php"
  cat >"$tmp/fpm.conf" <<EOF
[global]
pid = $tmp/run/fpm.pid
error_log = $tmp/fpm.log
daemonize = no
[www]
listen = $tmp/fpm.sock
pm = static
pm.max_children = 2
EOF
  "$tmp/php/sbin/php-fpm" -n -y "$tmp/fpm.conf" -F >>"$tmp/fpm.log" 2>&1 &
  fpid=$!
  for _ in $(seq 1 50); do [[ -S "$tmp/fpm.sock" ]] && break; sleep 0.1; done
  [[ -S "$tmp/fpm.sock" ]] || fail "php-fpm socket did not appear"
fi

# ---------------------------------------------------------------- httpd.conf
write_conf() {  # write_conf FILE LISTEN
  cat >"$1" <<EOF
ServerRoot "$ap"
Listen $2
ServerName 127.0.0.1
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule headers_module modules/mod_headers.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
DefaultRuntimeDir "$tmp/run"
PidFile "$tmp/run/httpd.pid"
ErrorLog "$tmp/error.log"
LogFormat "%h %r %>s" common
CustomLog "$tmp/access.log" common
TypesConfig conf/mime.types
DocumentRoot "$tmp/www"
<Directory "$tmp/www">
  Require all granted
</Directory>
DirectoryIndex index.php index.html
Header set X-RAMP-Smoke "ok"
RewriteEngine On
RewriteRule ^/rw$ /test.php [PT]
<FilesMatch "\.php$">
  SetHandler "proxy:unix:$tmp/fpm.sock|fcgi://localhost"
</FilesMatch>
EOF
}
write_conf "$tmp/httpd.conf" "127.0.0.1:$port"

httpd=("$ap/bin/httpd" -d "$ap" -f "$tmp/httpd.conf")
# -V with our -f: the compiled-in default conf points at the build stage, whose (ad-hoc) modules a
# Developer-ID/hardened-runtime httpd refuses to load (library validation: different Team ID).
v="$("${httpd[@]}" -V)" || die "httpd -V failed"
grep -E '^Server (version|MPM)' <<<"$v"
grep -q 'Server MPM: *event' <<<"$v" || die "httpd -V: MPM is not event"
mods="$("${httpd[@]}" -M 2>&1)" || { echo "$mods"; die "httpd -M failed"; }
for m in mpm_event_module proxy_fcgi_module rewrite_module headers_module; do
  grep -q " $m " <<<"$mods" || { echo "$mods"; die "httpd -M: $m missing"; }
done
log "httpd -M: mpm_event, proxy_fcgi, rewrite, headers loaded"
"${httpd[@]}" -t 2>&1 | grep -q 'Syntax OK' || die "config test failed"

"${httpd[@]}" -DFOREGROUND &
hpid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$port/index.html" >/dev/null 2>&1 && break; sleep 0.1; done

body="$(curl -fsS "http://127.0.0.1:$port/index.html")" || fail "static GET failed"
[[ "$body" == static-ok ]] || fail "static: got '$body'"
hdr="$(curl -fsSI "http://127.0.0.1:$port/index.html" | tr -d '\r')"
grep -qi '^X-RAMP-Smoke: ok' <<<"$hdr" || fail "mod_headers header missing"
log "static + mod_headers OK ($(grep -i '^Server:' <<<"$hdr"))"

if ((use_fpm)); then
  out="$(curl -fsS "http://127.0.0.1:$port/test.php")" || fail "PHP GET failed"
  echo "  $out"
  [[ "$out" == "php=$pver sapi=fpm-fcgi server=Apache"* ]] || fail "PHP via FPM: unexpected '$out'"
  out="$(curl -fsS "http://127.0.0.1:$port/rw")" || fail "rewrite GET failed"
  [[ "$out" == *"sapi=fpm-fcgi"* ]] || fail "rewrite → php: unexpected '$out'"
  log "Apache → PHP-FPM $pver OK (direct + RewriteRule)"
else
  log "FPM chain SKIPPED (NO_FPM=1)"
fi

kill "$hpid"; wait "$hpid" 2>/dev/null || true; hpid=""

# ---------------------------------------------------------------- Listen 80 as non-root
if lsof -nP -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1; then
  owner="$(lsof -nP -iTCP:80 -sTCP:LISTEN | awk 'NR==2{print $1" (pid "$2", user "$3")"}')"
  log "port 80 check SKIPPED — :80 already in use by $owner"
else
  write_conf "$tmp/httpd80.conf" "127.0.0.1:80"
  "$ap/bin/httpd" -d "$ap" -f "$tmp/httpd80.conf" -DFOREGROUND &
  hpid=$!
  ok=0
  for _ in $(seq 1 50); do curl -fs http://127.0.0.1:80/index.html >/dev/null 2>&1 && { ok=1; break; }; sleep 0.1; done
  kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true; hpid=""
  ((ok)) && log "port 80 bind as $(id -un) (non-root) OK" || fail "port 80 bind as non-root failed"
fi
log "apache smoke OK"
