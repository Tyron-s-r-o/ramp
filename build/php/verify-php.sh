#!/usr/bin/env bash
# verify-php.sh <php-root> [expected-version] — functional check of a relocatable PHP tree.
#
#   * php -v shows the version + "with Zend OPcache"
#   * php -m contains the full RAMP built-in extension set; gd has FreeType/JPEG/PNG/WebP
#   * no dylib is loaded from the build stage or Homebrew (DYLD_PRINT_LIBRARIES)
#   * php-fpm -t accepts a minimal config
# Sourcing it only defines render_test_ini <php-root> <out.ini> (used by smoke-fpm.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# render_test_ini ROOT OUT_INI
render_test_ini() {
  local root="$1" ini="$2" rel opc line
  rel="$(sed -n 's/.*"extension_dir_rel": "\(.*\)".*/\1/p' "$root/ramp.json")"
  opc="$(sed -n 's/.*"opcache": "\(.*\)".*/\1/p' "$root/ramp.json")"
  [[ "$opc" == shared ]] && line="zend_extension=opcache" || line=""
  sed -e "s|@EXTENSION_DIR@|$root/$rel|" -e "s|@OPCACHE_LINE@|$line|" "$here/php.ini-ramp-test" >"$ini"
}

# built-in extensions every RAMP PHP 8.x must report (php -m, lower-cased)
EXPECTED="bcmath bz2 calendar ctype curl dom exif fileinfo filter ftp gd gmp iconv intl mbstring
mysqli mysqlnd pdo_mysql pcntl pdo_sqlite session simplexml soap sockets sodium sqlite3 tokenizer
xml xmlreader xmlwriter xsl zip zlib openssl readline zend opcache"

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0   # sourced → only define helpers

root="$(cd "${1:?usage: verify-php.sh <php-root> [version]}" && pwd -P)"
want_ver="${2:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/ramp-verify-php.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ini="$work/php.ini"
render_test_ini "$root" "$ini"
php=("$root/bin/php" -c "$ini")
fail() { echo "verify-php: FAIL: $*" >&2; exit 1; }

v="$("${php[@]}" -v)"
[[ -z "$want_ver" || "$v" == "PHP $want_ver "* ]] || fail "version: $(head -1 <<<"$v")"
grep -q 'with Zend OPcache' <<<"$v" || fail "OPcache not loaded: $v"

mods=" $("${php[@]}" -m | tr 'A-Z' 'a-z' | tr '\n' ' ') "
missing=()
for m in $EXPECTED; do
  [[ "$mods" == *" $m "* || ( "$m" == zend && "$mods" == *" zend opcache "* ) ]] || missing+=("$m")
done
((${#missing[@]} == 0)) || fail "missing extensions: ${missing[*]}"

gd="$("${php[@]}" -r '$g=gd_info(); echo (int)$g["FreeType Support"], (int)$g["JPEG Support"], (int)$g["PNG Support"], (int)$g["WebP Support"];')"
[[ "$gd" == 1111 ]] || fail "gd features FreeType/JPEG/PNG/WebP = $gd"
"${php[@]}" -r 'exit(opcache_get_status() === false ? 1 : 0);' || fail "opcache not enabled in CLI"
ossl="$("${php[@]}" -r 'echo OPENSSL_VERSION_TEXT;')"
[[ "$ossl" == "OpenSSL 3."* ]] || fail "openssl: $ossl"

# dyld must resolve everything inside the tree (or /usr/lib, /System)
leaks="$(DYLD_PRINT_LIBRARIES=1 "${php[@]}" -r 'intl_get_error_code(); new XSLTProcessor; curl_version();' 2>&1 \
  | awk '/dyld/ && /\// {print $NF}' | grep -Ev "^($root/|/usr/lib/|/System/)" || true)"
[[ -z "$leaks" ]] || fail "libraries loaded from outside the tree: $leaks"

cat >"$work/fpm.conf" <<CONF
[global]
error_log = $work/fpm.log
daemonize = no
[www]
listen = $work/fpm.sock
pm = static
pm.max_children = 1
CONF
"$root/sbin/php-fpm" -c "$ini" -y "$work/fpm.conf" -t >"$work/fpm-t.out" 2>&1 || { cat "$work/fpm-t.out" >&2; fail "php-fpm -t"; }

echo "verify-php: OK $(head -1 <<<"$v" | awk '{print $2}') — ${root}"
