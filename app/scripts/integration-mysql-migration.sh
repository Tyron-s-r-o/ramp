#!/usr/bin/env bash
# MAMP MySQL migration engine end-to-end test (plan 07-04) on a SYNTHETIC MySQL 8.0 datadir.
#
# MAMP's mysqld 8.0 binary is used only as an executable on a fresh temp datadir — never MAMP's datadir,
# config, socket or port (MAMP may be running on 3306). RAMP packages come from build/dist (read-only).
# Sandbox: $RAMP_MIG_DIR (default /tmp/ramp-mig — short: unix sockets are limited to 103 bytes).
# Ports: synthetic 8.0 on 13380 (127.0.0.1), RAMP MySQL 13381. Every mysqld of the sandbox is stopped on exit.
#
# Env: RAMPCTL=<prebuilt rampctl>  SWIFT_SCRATCH=<swift build --scratch-path>  KEEP=1 (keep the sandbox)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
MANIFEST="$REPO/build/dist/manifest.json"
M80="/Applications/MAMP/Library/bin/mysql80/bin"
MAMP_DATADIR="/Library/Application Support/appsolute/MAMP PRO/db/mysql80"

if [[ ! -x "$M80/mysqld" ]]; then echo "SKIP  MAMP MySQL 8.0 binaries not found ($M80/mysqld)"; exit 0; fi
for f in "$MANIFEST" "$REPO"/build/dist/mysql-8.4.*-darwin-arm64.tar.xz "$REPO"/build/dist/mysql-9.7.*-darwin-arm64.tar.xz; do
    [[ -f "$f" ]] || { echo "SKIP  build/dist package missing: $f"; exit 0; }
done

T="${RAMP_MIG_DIR:-/tmp/ramp-mig}"
case "$T" in /tmp/*|/private/tmp/*) ;; *) echo "RAMP_MIG_DIR must be under /tmp" >&2; exit 2 ;; esac
if [[ -e "$T" && ! -f "$T/.ramp-mig-sandbox" && -n "$(ls -A "$T" 2>/dev/null)" ]]; then
    echo "$T exists and is not a ramp-mig sandbox — refusing" >&2; exit 2
fi
rm -rf "$T"
mkdir -p "$T"
T="$(cd "$T" && pwd -P)"
T="${T#/private}"                  # RAMP standardizes /private/tmp → /tmp
touch "$T/.ramp-mig-sandbox"
SRC="$T/src80" S80SOCK="$T/s80.sock" S80PID="$T/s80.pid"
[[ "$SRC" != "$MAMP_DATADIR"* ]] || { echo "sandbox overlaps MAMP datadir" >&2; exit 2; }
PORT80=13380 RAMP_PORT=13381
FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
now() { /usr/bin/python3 -c 'import time; print(time.time())'; }
since() { /usr/bin/python3 -c "import sys,time; print('%.1f' % (time.time() - float(sys.argv[1])))" "$1"; }

# --- process hygiene: only processes of this sandbox (argv mentions ramp-mig) -------------------------
sandbox_pids() { pgrep -f "$T/" 2>/dev/null | grep -v "^$$\$" || true; }
wait_gone() { local pid=$1; for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
stop_pidfile() {
    local f=$1 pid
    [[ -f "$f" ]] || return 0
    pid="$(cat "$f" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    wait_gone "$pid" || kill -9 "$pid" 2>/dev/null || true
}
cleanup() {
    local rc=$?
    stop_pidfile "$S80PID"
    for f in "$T"/h*/run/*.pid "$T"/h*/run/supervisor/*.pid; do [[ -f "$f" ]] && stop_pidfile "$f"; done
    local left; left="$(sandbox_pids | tr '\n' ' ')"
    if [[ -n "${left// /}" ]]; then echo "cleanup: killing leftover sandbox processes: $left" >&2; kill -9 $left 2>/dev/null || true; fi
    if [[ "${KEEP:-0}" != 1 ]]; then rm -rf "$T"; else echo "kept $T" >&2; fi
    exit $rc
}
trap cleanup EXIT INT TERM

# --- rampctl -------------------------------------------------------------------------------------------
if [[ -z "${RAMPCTL:-}" ]]; then
    SCRATCH_ARGS=()
    [[ -n "${SWIFT_SCRATCH:-}" ]] && SCRATCH_ARGS=(--scratch-path "$SWIFT_SCRATCH")
    swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --product rampctl >/dev/null
    RAMPCTL="$(swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --show-bin-path)/rampctl"
fi
r() { local home=$1; shift; RAMP_HOME="$T/$home" RAMP_LOGS="$T/$home/logs" "$RAMPCTL" "$@"; }

# --- synthetic MySQL 8.0 -------------------------------------------------------------------------------
m80() { MYSQL_PWD="${PW80:-}" "$M80/mysql" --no-defaults -S "$S80SOCK" -uroot "$@"; }
start80() {
    mkdir -p "$T/tmp80"
    "$M80/mysqld" --no-defaults --datadir="$SRC" --socket="$S80SOCK" --pid-file="$S80PID" --port=$PORT80 \
        --bind-address=127.0.0.1 --mysqlx=OFF --log-bin=binlog --server-id=1 --log-error="$T/s80.err" \
        --tmpdir="$T/tmp80" >/dev/null 2>&1 &
    for _ in $(seq 1 300); do [[ -S "$S80SOCK" ]] && return 0; sleep 0.1; done
    echo "synthetic 8.0 did not start"; tail -20 "$T/s80.err"; return 1
}
stop80() { stop_pidfile "$S80PID"; }
snapshot() {   # regular files: path size mtime; directories: path mtime
    { (cd "$SRC" && find . -type f -exec stat -f '%N %z %m' {} +)
      (cd "$SRC" && find . -type d -exec stat -f '%N d %m' {} +); } | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1
}

echo "== sandbox $T"
t0=$(now)
"$M80/mysqld" --no-defaults --initialize-insecure --datadir="$SRC" --log-error="$T/init80.err" >/dev/null 2>&1
start80
m80 <<'SQL'
CREATE DATABASE app_one CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE app_one;
CREATE TABLE customers (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100) NOT NULL, total INT NOT NULL DEFAULT 0) ENGINE=InnoDB;
CREATE TABLE orders (id INT PRIMARY KEY AUTO_INCREMENT, customer_id INT NOT NULL, amount INT NOT NULL, note TEXT,
  FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE USER 'app_owner'@'localhost' IDENTIFIED WITH mysql_native_password BY 'owner';
GRANT ALL ON app_one.* TO 'app_owner'@'localhost';
CREATE DEFINER='app_owner'@'localhost' TRIGGER orders_ai AFTER INSERT ON orders FOR EACH ROW
  UPDATE customers SET total = total + NEW.amount WHERE id = NEW.customer_id;
CREATE DEFINER='app_owner'@'localhost' SQL SECURITY DEFINER VIEW customer_totals AS
  SELECT c.name, c.total, COUNT(o.id) AS n FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id;
DELIMITER //
CREATE DEFINER='app_owner'@'localhost' PROCEDURE add_order(IN cid INT, IN amt INT)
BEGIN INSERT INTO orders (customer_id, amount) VALUES (cid, amt); END //
DELIMITER ;
INSERT INTO customers (name) VALUES ('alice'), ('bob'), ('čučoriedka');
CALL add_order(1, 10); CALL add_order(1, 5); CALL add_order(2, 7);
CREATE DATABASE `app-two` CHARACTER SET latin1 COLLATE latin1_swedish_ci;
CREATE TABLE `app-two`.items (id INT PRIMARY KEY, label VARCHAR(50), data BLOB) ENGINE=InnoDB;
INSERT INTO `app-two`.items VALUES (1, 'x', 0x00FF10), (2, 'y', NULL);
CREATE USER 'legacy'@'localhost' IDENTIFIED WITH mysql_native_password BY 'legacy';
GRANT SELECT ON `app-two`.* TO 'legacy'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root';
SQL
PW80=root
m80 -e "SET PERSIST max_connections = 300;
  CREATE TABLE app_one.junk (id INT PRIMARY KEY AUTO_INCREMENT, pad VARCHAR(2000));
  INSERT INTO app_one.junk (pad) VALUES (REPEAT('x', 2000));
  $(for _ in $(seq 1 12); do printf 'INSERT INTO app_one.junk (pad) SELECT pad FROM app_one.junk; '; done)
  DROP TABLE app_one.junk; FLUSH BINARY LOGS; SET GLOBAL innodb_fast_shutdown = 0;"
stop80
binlogs="$(ls "$SRC" | grep -c '^binlog\.' || true)"
if [[ "$binlogs" -ge 2 && -f "$SRC/mysqld-auto.cnf" && -d "$SRC/app@002dtwo" ]]; then
    pass "1 synthetic 8.0.40 datadir: 2 schemas (app_one, app-two), native users, $binlogs binlog files, mysqld-auto.cnf ($(since "$t0") s)"
else
    fail "1 synthetic datadir incomplete (binlogs=$binlogs)"
fi

# --- base RAMP home (installed once, cloned per scenario) --------------------------------------------
mkdir -p "$T/base/logs"
/usr/bin/python3 - "$T/base/ramp.json" <<PY
import json, sys
json.dump({"schemaVersion": 1, "apache": {"port": 18381}, "redis": {"port": 16381},
           "mysql": {"port": $RAMP_PORT, "innodbBufferPoolSize": "256M", "maxAllowedPacket": "64M"}},
          open(sys.argv[1], "w"), indent=2)
PY
t=$(now)
r base install --manifest "file://$MANIFEST" | tail -1
info "rampctl install (default set) $(since "$t") s"
home() { cp -cR "$T/base" "$T/$1"; }

# RAMP mysqld started straight from the generated my.cnf (proves the config fits the migrated datadir)
ramp_start() {
    local h=$1 b=${2:-9.7}
    "$T/$h/mysql/$b/current/bin/mysqld" --defaults-file="$T/$h/conf/mysql/$b/my.cnf" >/dev/null 2>&1 &
    for _ in $(seq 1 600); do [[ -S "$T/$h/run/mysql$b.sock" ]] && return 0; sleep 0.1; done
    echo "RAMP mysql $b did not start"; tail -20 "$T/$h/logs/mysql$b.err"; return 1
}
ramp_stop() { stop_pidfile "$T/$1/run/mysql${2:-9.7}.pid"; }
rq() { local h=$1 b=$2 u=$3 p=$4; shift 4; MYSQL_PWD="$p" "$T/$h/mysql/$b/current/bin/mysql" --no-defaults -S "$T/$h/run/mysql$b.sock" -u"$u" -N -B "$@"; }

# (5) in-use refusal (before the snapshot: starting 8.0 touches the synthetic source)
home h1
start80
set +e
out="$(r h1 import mysql precheck --source "$SRC" --source-socket "$S80SOCK" 2>&1)"; pc=$?
out2="$(r h1 import mysql run --method datadir --source "$SRC" --source-socket "$S80SOCK" --root-password-stdin <<< root 2>&1)"; rc=$?
set -e
if [[ $pc == 2 && "$out" == *"sourceInUse"* && $rc == 3 && "$out2" == *"sourceInUse"* && "$out2" == *"ibdata1 is locked"* ]]; then
    pass "5 source running → precheck blocker + run exit 3 sourceInUse (ibdata1 lock + mysqld argv + socket)"
else
    fail "5 in-use: precheck=$pc run=$rc"; echo "$out2" | tail -5
fi
[[ ! -e "$T/h1/.staging/mamp-import/datadir" ]] && pass "5 refused run created no copy" || fail "5 copy exists after refusal"
stop80
r h1 import mysql discard >/dev/null

# (2) source snapshot
SNAP="$(snapshot)"
info "2 source snapshot $SNAP"

# (4) precheck
set +e; out="$(r h1 import mysql precheck --source "$SRC" 2>&1)"; pc=$?; set -e
echo "$out" | sed 's/^/      /'
if [[ $pc == 0 && "$out" == *"binlogs:"*"(excluded)"* && "$out" == *"schemas:         2 (app-two, app_one)"* \
      && "$out" == *"clone possible:  yes"* && "$out" == *"precheck: OK"* ]]; then
    pass "4 precheck: 2 schemas, binlogs excluded, clone possible, OK"
else
    fail "4 precheck (exit $pc)"
fi

# (6) datadir method: clone → 8.4 → users → 9.7 → verify → activate
t=$(now)
set +e; out="$(r h1 import mysql run --method datadir --source "$SRC" --root-password-stdin <<< root 2>&1)"; rc=$?; set -e
dur6=$(since "$t")
echo "$out" | grep -v "^copy:\|^step\|^phase" | sed 's/^/      /'
[[ $rc == 0 && "$out" == *"phase activated"* ]] && pass "6 datadir migration activated in $dur6 s" || fail "6 datadir run exit $rc"
[[ "$out" == *"Server upgrade from '80040' to '80411' completed"* && "$out" == *"Server upgrade from '80411' to '90702' completed"* ]] \
    && pass "6 error log markers 8.0.40→8.4.11 and 8.4.11→9.7.2 upgrade completed" || fail "6 upgrade markers missing"
[[ "$out" == *"unconverted (cannot log in on 9.x): 'legacy'@'localhost'"* && "$out" == *"converted: 'root'@'localhost' mysql_native_password → caching_sha2_password"* ]] \
    && pass "6 root converted to caching_sha2_password; legacy reported unconverted" || fail "6 account report"
D="$T/h1/mysql-data/9.7"
nb="$(ls "$D" | grep -c '^binlog\.' || true)"
[[ "$nb" == 0 && ! -e "$D/mysqld-auto.cnf" ]] && pass "6 target has no binlog.* and no mysqld-auto.cnf" || fail "6 target has binlogs ($nb) or mysqld-auto.cnf"
[[ ! -e "$T/h1/.staging/mamp-import/datadir" ]] && pass "6 staging copy renamed into mysql-data/9.7" || fail "6 staging copy left"
[[ -z "$(ls "$T/h1/.staging/mamp-import/tmp" 2>/dev/null)" ]] && [[ -z "$(find "$T/h1" -name '.client-*.cnf')" ]] \
    && pass "6 no credential files left" || fail "6 credential files left"
[[ ! -e "$T/h1/mysql/8.4" ]] && pass "6 mysql 8.4 package removed after success (no --keep-84)" || fail "6 mysql 8.4 still installed"
ramp_start h1
v="$(rq h1 9.7 root root -e 'SELECT VERSION()')"
[[ "$v" == 9.7.2 ]] && pass "6 RAMP mysqld (generated my.cnf) SELECT VERSION() = $v as root/root" || fail "6 version '$v'"
rows="$(rq h1 9.7 root root -e "SELECT (SELECT COUNT(*) FROM app_one.customers),(SELECT COUNT(*) FROM app_one.orders),(SELECT COUNT(*) FROM \`app-two\`.items),(SELECT HEX(data) FROM \`app-two\`.items WHERE id=1),(SELECT name FROM app_one.customers WHERE id=3)")"
[[ "$rows" == $'3\t3\t2\t00FF10\tčučoriedka' ]] && pass "6 row counts + blob + utf8mb4 intact ($rows)" || fail "6 rows '$rows'"
rq h1 9.7 root root -e "CALL app_one.add_order(2, 1)"
tv="$(rq h1 9.7 root root -e "SELECT total, n FROM app_one.customer_totals WHERE name='bob'")"
[[ "$tv" == $'8\t2' ]] && pass "6 procedure + trigger + view work on 9.7 (bob total/n = $tv)" || fail "6 proc/trigger/view '$tv'"
lct="$(rq h1 9.7 root root -e 'SELECT @@lower_case_table_names')"
info "6 lower_case_table_names on RAMP 9.7 with generated my.cnf = $lct"
set +e; lg="$(rq h1 9.7 legacy legacy -e 'SELECT 1' 2>&1)"; set -e
info "6 legacy login on 9.7: $lg"
ramp_stop h1

# (7) source untouched
[[ "$(snapshot)" == "$SNAP" ]] && pass "7 source snapshot identical (sizes + mtimes of every file/dir)" || fail "7 SOURCE CHANGED"

# (8) resume after an interrupted copy
home h2
set +e
out="$(RAMP_TEST_FAIL_AFTER_FILES=5 r h2 import mysql run --method datadir --source "$SRC" --root-password-stdin <<< root 2>&1)"; rc=$?
st="$(r h2 import mysql status 2>&1)"
out2="$(r h2 import mysql run --method datadir --source "$SRC" --root-password-stdin <<< root 2>&1)"; rc2=$?
set -e
if [[ $rc == 1 && "$st" == *"phase copying"* && "$st" == *"FAILED at copied"* && $rc2 == 0 && "$out2" == *"phase activated"* \
      && "$out2" =~ copy:\ [0-9]+\ files\ copied,\ 5\ skipped ]]; then
    pass "8 interrupted after 5 files (state copying) → rerun resumed (5 skipped) → activated"
else
    fail "8 resume: first=$rc second=$rc2"; echo "$st" | head -3; echo "$out2" | tail -8
fi
[[ "$(snapshot)" == "$SNAP" ]] && pass "8 source still identical" || fail "8 SOURCE CHANGED"

# (10) ISS-004: legacy re-hashed to sha256_password (PHP 7.3-compatible) on 9.7
home h4
set +e
out="$(r h4 import mysql run --method datadir --source "$SRC" --root-password-stdin --auth 'legacy@localhost=sha256_password' <<< $'root\nlegacy@localhost\tlegacy' 2>&1)"; rc=$?
set -e
if [[ $rc == 0 && "$out" == *"converted: 'legacy'@'localhost' mysql_native_password → sha256_password"* ]]; then
    ramp_start h4
    lg="$(rq h4 9.7 legacy legacy -e "SELECT COUNT(*) FROM \`app-two\`.items" 2>&1 || true)"
    pl="$(rq h4 9.7 root root -e "SELECT plugin FROM mysql.user WHERE user='legacy'")"
    ramp_stop h4
    [[ "$lg" == 2 && "$pl" == sha256_password ]] && pass "10 --auth legacy@localhost=sha256_password → login on 9.7 OK ($pl)" \
        || fail "10 sha256 login '$lg' plugin '$pl'"
else
    fail "10 sha256 run exit $rc"; echo "$out" | tail -5
fi

# (11) ISS-004: stop at 8.4, keep mysql_native_password
home h5
set +e; out="$(r h5 import mysql run --method datadir --target 8.4 --source "$SRC" --root-password-stdin <<< root 2>&1)"; rc=$?; set -e
if [[ $rc == 0 && "$out" == *"kept mysql_native_password: 'legacy'@'localhost'"* && -d "$T/h5/mysql-data/8.4" ]] \
   && grep -q '^mysql-native-password=ON' "$T/h5/conf/mysql/8.4/my.cnf"; then
    ramp_start h5 8.4
    v="$(rq h5 8.4 root root -e 'SELECT VERSION()' 2>&1 || true)"
    lg="$(rq h5 8.4 legacy legacy -e "SELECT COUNT(*) FROM \`app-two\`.items" 2>&1 || true)"
    ramp_stop h5 8.4
    [[ "$v" == 8.4.11 && "$lg" == 2 ]] && pass "11 --target 8.4: RAMP 8.4.11 (my.cnf mysql-native-password=ON), legacy native login OK" \
        || fail "11 8.4 version '$v' legacy '$lg'"
else
    fail "11 8.4 target exit $rc"; echo "$out" | tail -5
fi

# (9) logical method: running source → per-DB dump → RAMP 9.7
home h3
set +e; out="$(r h3 import mysql run --method logical --source "$SRC" --source-socket "$S80SOCK" --root-password-stdin <<< root 2>&1)"; rc=$?; set -e
[[ $rc == 1 && "$out" == *"not reachable"* ]] && pass "9 logical refused while the source server is stopped" || fail "9 logical without source: exit $rc"
start80
t=$(now)
set +e; out="$(r h3 import mysql run --method logical --source "$SRC" --source-socket "$S80SOCK" --root-password-stdin <<< root 2>&1)"; rc=$?; set -e
dur9=$(since "$t")
echo "$out" | grep -v "^step\|^phase" | sed 's/^/      /'
[[ $rc == 0 && "$out" == *"phase imported"* && "$out" == *"imported databases: app-two, app_one"* ]] \
    && pass "9 logical import of 2 databases in $dur9 s" || fail "9 logical exit $rc"
ramp_start h3
rows="$(rq h3 9.7 root root -e "SELECT (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='app_one'),(SELECT COUNT(*) FROM app_one.orders),(SELECT COUNT(*) FROM \`app-two\`.items),(SELECT HEX(data) FROM \`app-two\`.items WHERE id=1),(SELECT default_collation_name FROM information_schema.schemata WHERE schema_name='app-two')")"
[[ "$rows" == $'3\t3\t2\t00FF10\tlatin1_swedish_ci' ]] && pass "9 tables/rows/blob/collation match ($rows)" || fail "9 rows '$rows'"
defs="$(rq h3 9.7 root root -e "SELECT CONCAT((SELECT definer FROM information_schema.views WHERE table_schema='app_one'),' ',(SELECT definer FROM information_schema.triggers WHERE trigger_schema='app_one'),' ',(SELECT definer FROM information_schema.routines WHERE routine_schema='app_one'))")"
[[ "$defs" == "root@localhost root@localhost root@localhost" ]] && pass "9 DEFINERs rewritten to CURRENT_USER ($defs)" || fail "9 definers '$defs'"
rq h3 9.7 root root -e "CALL app_one.add_order(2, 1)"
tv="$(rq h3 9.7 root root -e "SELECT total, n FROM app_one.customer_totals WHERE name='bob'")"
[[ "$tv" == $'8\t2' ]] && pass "9 procedure + trigger + view work after logical import" || fail "9 proc/trigger/view '$tv'"
ramp_stop h3
stop80

sleep 0.3
left="$(sandbox_pids | tr '\n' ' ')"
[[ -z "${left// /}" ]] && pass "no sandbox processes left" || fail "leftover processes: $left"
if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
echo "RESULT: all checks PASS"
