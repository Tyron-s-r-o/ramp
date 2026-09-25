#!/usr/bin/env bash
# smoke-fpm.sh <version> [php-root] — start php-fpm on a unix socket in a temp dir, send one
# FastCGI request (mini client written in PHP, run by the same tree's CLI), stop fpm.
#
#   build/php/smoke-fpm.sh 8.3.35                 # tests build/out/php/8.3.35
#   build/php/smoke-fpm.sh 8.3.35 /some/moved/dir # tests a copied/moved tree
#
# Success output:  smoke-fpm: OK <version> intl=1
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/verify-php.sh"   # render_test_ini

ver="${1:?usage: smoke-fpm.sh <version> [php-root]}"
root="${2:-$here/../out/php/$ver}"
root="$(cd "$root" && pwd -P)"
[[ -x "$root/sbin/php-fpm" ]] || { echo "smoke-fpm: no php-fpm in $root" >&2; exit 1; }

# short dir: unix socket paths are limited to 104 bytes
work="$(mktemp -d /tmp/ramp-fpm.XXXXXX)"
fpm_pid=""
cleanup() {
  if [[ -n "$fpm_pid" ]] && kill -0 "$fpm_pid" 2>/dev/null; then
    kill -QUIT "$fpm_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$fpm_pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$fpm_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

ini="$work/php.ini"
render_test_ini "$root" "$ini"
mkdir -p "$work/www"
cat >"$work/www/index.php" <<'PHP'
<?php echo PHP_VERSION, ' ', (int) extension_loaded('intl'), "\n";
PHP
cat >"$work/fpm.conf" <<CONF
[global]
pid = $work/fpm.pid
error_log = $work/fpm.log
daemonize = no
[www]
listen = $work/fpm.sock
pm = static
pm.max_children = 2
catch_workers_output = yes
CONF

# FastCGI responder client: BEGIN_REQUEST, PARAMS, empty PARAMS, empty STDIN → collect STDOUT
cat >"$work/fcgi.php" <<'PHP'
<?php
[$_, $sock, $script] = $argv;
$c = stream_socket_client("unix://$sock", $errno, $errstr, 5) or exit("connect: $errstr\n");
// no arrow functions: this client also runs on PHP 7.3
$rec = function (int $type, string $body): string { return pack('CCnnCx', 1, $type, 1, strlen($body), 0) . $body; };
$nv = function (string $k, string $v): string {
    $len = function ($s) { return strlen($s) < 128 ? chr(strlen($s)) : pack('N', strlen($s) | 0x80000000); };
    return $len($k) . $len($v) . $k . $v;
};
$params = '';
foreach ([
    'SCRIPT_FILENAME' => $script, 'SCRIPT_NAME' => '/index.php', 'REQUEST_METHOD' => 'GET',
    'REQUEST_URI' => '/index.php', 'QUERY_STRING' => '', 'SERVER_PROTOCOL' => 'HTTP/1.1',
    'GATEWAY_INTERFACE' => 'CGI/1.1', 'SERVER_NAME' => 'localhost', 'SERVER_PORT' => '80',
    'REMOTE_ADDR' => '127.0.0.1', 'CONTENT_LENGTH' => '0',
] as $k => $v) { $params .= $nv($k, $v); }
fwrite($c, $rec(1, pack('nCx5', 1, 0)) . $rec(4, $params) . $rec(4, '') . $rec(5, ''));
$out = $err = '';
while (!feof($c)) {
    $h = fread($c, 8);
    if (strlen($h) < 8) break;
    $r = unpack('Cver/Ctype/nid/nlen/Cpad/Cres', $h);
    $body = $r['len'] ? stream_get_contents($c, $r['len']) : '';
    if ($r['pad']) fread($c, $r['pad']);
    if ($r['type'] === 6) $out .= $body;
    elseif ($r['type'] === 7) $err .= $body;
    elseif ($r['type'] === 3) break;
}
if ($err !== '') fwrite(STDERR, "fcgi stderr: $err\n");
$parts = explode("\r\n\r\n", $out, 2);
echo $parts[1] ?? $out;
PHP

OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES "$root/sbin/php-fpm" -F -c "$ini" -y "$work/fpm.conf" \
  >"$work/fpm.out" 2>&1 &
fpm_pid=$!
for _ in $(seq 1 50); do [[ -S "$work/fpm.sock" ]] && break; sleep 0.1; done
if [[ ! -S "$work/fpm.sock" ]]; then
  echo "smoke-fpm: php-fpm did not open its socket" >&2
  cat "$work/fpm.out" "$work/fpm.log" 2>/dev/null >&2 || true
  exit 1
fi

resp="$("$root/bin/php" -c "$ini" "$work/fcgi.php" "$work/fpm.sock" "$work/www/index.php")"
resp="${resp%$'\n'}"
if [[ "$resp" != "$ver 1" ]]; then
  echo "smoke-fpm: FAIL — expected '$ver 1', got '$resp'" >&2
  cat "$work/fpm.log" 2>/dev/null >&2 || true
  exit 1
fi
echo "smoke-fpm: OK $ver intl=${resp##* } ($root)"
