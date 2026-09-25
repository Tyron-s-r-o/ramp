#!/usr/bin/env bash
# smoke-mysql.sh [9.7|8.4 …] — initialize-insecure a scratch datadir, run mysqld on :13306
# (never 3306 = MAMP), `select version()`, shut down via mysqladmin. Runs from a moved copy of out/.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

series=("$@"); ((${#series[@]})) || series=(9.7 8.4)
port="${SMOKE_PORT:-13306}"

for s in "${series[@]}"; do
  ver_var="MYSQL${s//./}_VERSION"; ver="${!ver_var}"
  src="$OUT_DIR/mysql/$ver"
  [[ -x "$src/bin/mysqld" ]] || die "mysql $ver not fetched ($src) — run fetch-mysql.sh"
  # short base dir: unix socket paths are limited to 104 bytes on macOS
  tmp="$(mktemp -d /tmp/ramp-my.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$src" "$tmp/base"
  base="$tmp/base" data="$tmp/data" sock="$tmp/my.sock"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && die "port $port busy"

  "$base/bin/mysqld" --no-defaults --initialize-insecure --basedir="$base" --datadir="$data" \
    --log-error="$tmp/init.err" || { cat "$tmp/init.err" >&2; die "mysql $ver: initialize failed"; }

  "$base/bin/mysqld" --no-defaults --basedir="$base" --datadir="$data" --port="$port" \
    --bind-address=127.0.0.1 --socket="$sock" --mysqlx=OFF --skip-log-bin \
    --pid-file="$tmp/mysqld.pid" --log-error="$tmp/mysqld.err" &
  pid=$!
  for _ in $(seq 1 100); do
    "$base/bin/mysqladmin" --no-defaults -uroot --socket="$sock" ping >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || { cat "$tmp/mysqld.err" >&2; die "mysql $ver: mysqld died"; }
    sleep 0.2
  done
  got="$("$base/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P"$port" -N -e 'select version()')"
  "$base/bin/mysqladmin" --no-defaults -uroot --socket="$sock" shutdown
  wait "$pid" || true
  rm -rf "$tmp"; trap - EXIT
  [[ "$got" == "$ver" ]] || die "mysql smoke: expected $ver, got '$got'"
  log "mysql smoke OK: select version() = $got (TCP 127.0.0.1:$port, moved copy)"
done
