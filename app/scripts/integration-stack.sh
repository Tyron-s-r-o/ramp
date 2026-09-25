#!/usr/bin/env bash
# End-to-end stack test (plan 02-05): installs the real packages from build/dist/manifest.json into a
# throw-away RAMP_HOME, runs `rampctl up` on alternate ports (Apache 18080, MySQL 13306, Redis 16379 —
# never 80/3306/6379, MAMP may be running) and checks Apache→FPM, MySQL, Redis, crash recovery,
# graceful reload and a clean stop.
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dir)
#      RAMP_IT_DIR=<existing empty dir, short path — unix sockets are limited to 103 bytes>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
MANIFEST="$REPO/build/dist/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST — run Phase 1 (build/dist) first" >&2; exit 2; }

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-it.XXXXXX)}"
mkdir -p "$IT"
IT="$(cd "$IT" && pwd -P)"          # /tmp → /private/tmp: executable paths must match RAMP_HOME
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
export RAMP_TMP_MYSQL_SOCK="$IT/mysql.sock"   # never touch the real /tmp/mysql.sock
mkdir -p "$RAMP_HOME" "$RAMP_LOGS" "$IT/sites"

APACHE_PORT=18080 MYSQL_PORT=13306 REDIS_PORT=16379
BASE="http://127.0.0.1:$APACHE_PORT"
FAILS=0
UP_PID=""
HOME_PAT="${RAMP_HOME#/private}"    # RAMP standardizes /private/tmp → /tmp in argv
PGIDS=""                            # every service master seen (= its process group id)

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

note_pgids() {
    local f
    for f in "$RAMP_HOME"/run/supervisor/*.pid; do [[ -f "$f" ]] && PGIDS="$PGIDS $(cat "$f")"; done
    return 0
}
# Processes of this sandbox: argv mentions the root, or member of a service process group
# (php-fpm workers retitle themselves "php-fpm: pool www" — no path in argv).
leftovers() {
    { pgrep -f "$HOME_PAT" || true
      ps -axo pid=,pgid= | awk -v s="$PGIDS" 'BEGIN { n = split(s, a, " "); for (i = 1; i <= n; i++) g[a[i]] = 1 }
                                               ($2 in g) { print $1 }'
    } | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

cleanup() {
    local rc=$?
    if [[ -n "$UP_PID" ]] && kill -0 "$UP_PID" 2>/dev/null; then
        kill -TERM "$UP_PID" 2>/dev/null || true
        for _ in $(seq 1 150); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
    fi
    # Safety net: anything still running from this temp root (never touches other processes).
    local left
    left="$(leftovers)"
    if [[ -n "$left" ]]; then
        echo "cleanup: killing leftover processes: $left" >&2
        kill -9 $left 2>/dev/null || true
    fi
    if [[ "${KEEP:-0}" != 1 ]]; then rm -rf "$IT"; else echo "kept $IT" >&2; fi
    exit $rc
}
trap cleanup EXIT INT TERM

# --- rampctl -------------------------------------------------------------------------------------
if [[ -z "${RAMPCTL:-}" ]]; then
    SCRATCH_ARGS=()
    [[ -n "${SWIFT_SCRATCH:-}" ]] && SCRATCH_ARGS=(--scratch-path "$SWIFT_SCRATCH")
    swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --product rampctl >/dev/null
    RAMPCTL="$(swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --show-bin-path)/rampctl"
fi

# --- branches + test vhosts (one per PHP branch) --------------------------------------------------
PHP_BRANCHES=()
while IFS= read -r line; do PHP_BRANCHES+=("$line"); done < <(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for b in sorted(m["components"]["php"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(b + " " + m["components"]["php"][b]["version"])
PY
)
DEFAULT_VERSION="${PHP_BRANCHES[${#PHP_BRANCHES[@]}-1]#* }"

for entry in "${PHP_BRANCHES[@]}"; do
    b="${entry% *}"; d="$IT/sites/php${b//./}"
    mkdir -p "$d"
    printf '<?php echo "PHPV=" . PHP_VERSION . " SAPI=" . PHP_SAPI;\n' > "$d/index.php"
    cat > "$d/db.php" <<PHP
<?php
mysqli_report(MYSQLI_REPORT_OFF);
\$m = @mysqli_connect('127.0.0.1', 'root', 'root', '', $MYSQL_PORT);
echo \$m ? 'DBOK ' . mysqli_get_server_info(\$m) : 'DBERR ' . mysqli_connect_errno() . ' ' . mysqli_connect_error();
PHP
done

/usr/bin/python3 - "$RAMP_HOME/ramp.json" "$IT/sites" "${PHP_BRANCHES[@]}" <<PY
import json, sys, uuid
out, sites, entries = sys.argv[1], sys.argv[2], sys.argv[3:]
vhosts = []
for e in entries:
    b = e.split(" ")[0]; tag = b.replace(".", "")
    vhosts.append({"id": str(uuid.uuid4()), "domain": f"php{tag}.local", "aliases": [],
                   "docroot": f"{sites}/php{tag}", "phpBranch": b, "enabled": True})
cfg = {"schemaVersion": 1,
       "apache": {"port": $APACHE_PORT, "listenAddresses": ["127.0.0.1", "::1"]},
       "mysql": {"port": $MYSQL_PORT, "innodbBufferPoolSize": "256M", "maxAllowedPacket": "64M"},
       "redis": {"port": $REDIS_PORT},
       "vhosts": vhosts}
json.dump(cfg, open(out, "w"), indent=2)
PY

echo "== sandbox $IT"
echo "== install"
"$RAMPCTL" install --manifest "file://$MANIFEST"

MYSQL_BIN="$RAMP_HOME/mysql/9.7/current/bin/mysql"
REDIS_CLI="$(ls -d "$RAMP_HOME"/redis/*/current | tail -1)/bin/redis-cli"
sql() { MYSQL_PWD=root "$MYSQL_BIN" --no-defaults --protocol=TCP -h127.0.0.1 -P"$MYSQL_PORT" -uroot -N -B -e "$1"; }
pidof_svc() { cat "$RAMP_HOME/run/supervisor/$1.pid" 2>/dev/null || true; }
host_get() { curl -fsS --max-time 10 -H "Host: $1" "$BASE/${2:-}"; }

echo "== up"
"$RAMPCTL" up > "$IT/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 900); do
    grep -q -- "--- stack up" "$IT/up.log" 2>/dev/null && break
    kill -0 "$UP_PID" 2>/dev/null || break
    sleep 0.2
done
cat "$IT/up.log"
note_pgids
grep -q -- "--- stack up (all services running)" "$IT/up.log" || fail "stack did not come up cleanly"

# (1) default site → phpinfo of the newest branch through FPM
body="$(curl -fsS --max-time 10 "$BASE/" || true)"
if [[ "$body" == *"PHP Version $DEFAULT_VERSION"* || ( "$body" == *"PHP Version"* && "$body" == *"$DEFAULT_VERSION"* ) ]] \
   && [[ "$body" == *"FPM/FastCGI"* ]]; then
    pass "1 http://127.0.0.1:$APACHE_PORT/ phpinfo PHP $DEFAULT_VERSION, Server API FPM/FastCGI"
else
    fail "1 default phpinfo (expected PHP $DEFAULT_VERSION via FPM/FastCGI)"
fi

# (2) every branch through its own vhost → own FPM socket
for entry in "${PHP_BRANCHES[@]}"; do
    b="${entry% *}"; v="${entry#* }"
    got="$(host_get "php${b//./}.local" || true)"
    if [[ "$got" == "PHPV=$v SAPI=fpm-fcgi" ]]; then pass "2 php $b vhost → $got"; else fail "2 php $b vhost → '$got'"; fi
done

# (3) MySQL: root/root over TCP, 9.7.x, no binlog, no X Protocol
row="$(sql 'select version(), @@log_bin' 2>&1 || true)"
xplugin="$(sql "select count(*) from information_schema.plugins where plugin_name='mysqlx' and plugin_status='ACTIVE'" 2>&1 || true)"
if [[ "$row" == 9.7.*$'\t'0 && "$xplugin" == 0 ]]; then pass "3 mysql root login: version/log_bin '$row', mysqlx active=$xplugin"
else fail "3 mysql: '$row' mysqlx='$xplugin'"; fi
if lsof -nP -iTCP:33060 -sTCP:LISTEN 2>/dev/null | grep -q "$(pidof_svc mysql9.7)"; then fail "3 mysqlx listening on 33060"; fi

# (4) Redis
[[ "$("$REDIS_CLI" -p "$REDIS_PORT" ping 2>&1)" == PONG ]] && pass "4 redis PONG" || fail "4 redis ping"

# (5) crash recovery
old="$(pidof_svc redis)"; kill -9 "$old"
ok=0
for _ in $(seq 1 50); do
    sleep 0.1
    new="$(pidof_svc redis)"
    if [[ -n "$new" && "$new" != "$old" ]] && [[ "$("$REDIS_CLI" -p "$REDIS_PORT" ping 2>/dev/null)" == PONG ]]; then ok=1; break; fi
done
[[ $ok == 1 ]] && pass "5 redis kill -9 $old → back as $new" || fail "5 redis not back within 5 s"
note_pgids

lastb="${PHP_BRANCHES[${#PHP_BRANCHES[@]}-1]% *}"
old="$(pidof_svc "php$lastb-fpm")"; kill -9 "$old"
ok=0
for _ in $(seq 1 50); do
    sleep 0.1
    new="$(pidof_svc "php$lastb-fpm")"
    body="$(curl -fsS --max-time 2 "$BASE/" 2>/dev/null || true)"
    if [[ -n "$new" && "$new" != "$old" && "$body" == *"PHP Version"* ]]; then ok=1; break; fi
done
[[ $ok == 1 ]] && pass "5 php$lastb-fpm kill -9 $old → back as $new, phpinfo OK" || fail "5 php$lastb-fpm not back within 5 s"
note_pgids
orphans="$(ps -axo pid=,pgid= | awk -v g="$old" '$2 == g { print $1 }' | tr '\n' ' ')"
[[ -z "$orphans" ]] && pass "5 no orphaned workers of killed master $old" || fail "5 orphaned workers of $old: $orphans"

# (6) graceful reload keeps every FPM master and the httpd master
fpm_pids() { for entry in "${PHP_BRANCHES[@]}"; do printf '%s ' "$(pidof_svc "php${entry% *}-fpm")"; done; }
before="$(fpm_pids)"; httpd_before="$(pidof_svc apache)"
"$RAMPCTL" reload
sleep 2
after="$(fpm_pids)"; httpd_after="$(pidof_svc apache)"
body="$(curl -fsS --max-time 5 "$BASE/" 2>/dev/null || true)"
if [[ "$before" == "$after" && "$httpd_before" == "$httpd_after" && "$body" == *"PHP Version"* ]] \
   && grep -q "\[apache\] reloaded" "$IT/up.log"; then
    pass "6 rampctl reload: Apache reloaded (pid $httpd_after), FPM pids unchanged ($after)"
else
    fail "6 reload: fpm '$before' → '$after', httpd $httpd_before → $httpd_after"
fi

# (7) mysqli over TCP with caching_sha2_password (MySQL 9 has no mysql_native_password) — report only.
#     FLUSH PRIVILEGES empties the sha2 cache → every branch has to do the full (RSA) authentication.
for entry in "${PHP_BRANCHES[@]}"; do
    b="${entry% *}"
    sql 'flush privileges' >/dev/null 2>&1 || true
    cold="$(host_get "php${b//./}.local" db.php 2>&1 || true)"
    warm="$(host_get "php${b//./}.local" db.php 2>&1 || true)"
    info "7 php $b mysqli caching_sha2 cold: $cold | warm: $warm"
done

# (8) stop → nothing left
kill -TERM "$UP_PID"
for _ in $(seq 1 300); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$UP_PID" 2>/dev/null; then fail "8 rampctl up did not exit"; fi
UP_PID=""
sleep 0.5
left="$(leftovers)"
if [[ -z "$left" ]]; then pass "8 SIGTERM rampctl up → no RAMP processes left (checked argv + process groups:$PGIDS)"
else fail "8 leftovers: $left"; ps -o pid,pgid,command -p "${left// /,}" || true; fi

echo "== up.log tail"; tail -5 "$IT/up.log"
if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
echo "RESULT: all required checks PASS"
