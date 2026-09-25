#!/usr/bin/env bash
# phpMyAdmin integration test (plan 04-04): installs the real packages from build/dist/manifest.json into a
# throw-away RAMP_HOME, runs `rampctl up` (MySQL bootstrapped, 02-05) on alternate ports and proves:
#   (1) /phpmyadmin/ auto-logs in as root over the MySQL socket (no login form)
#   (2) it runs on the newest enabled PHP branch (alias block → newest FPM socket + PHP version on the page)
#   (3) internals (setup/, libraries/, …, .user.ini) → 403
#   (4) not exposed on project vhosts (p83.t.local/phpmyadmin/ → 404)
#   (5) blowfish secret stable across `rampctl reload`; config.inc.php 0600 (php -l OK); tmp dir 0700
#   (6) no PHP deprecation/warning text in the pages
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dir)
#      RAMP_IT_DIR=<existing empty dir, short path — unix sockets are limited to 103 bytes>
#      APACHE_PORT / MYSQL_PORT / REDIS_PORT (defaults 18080 / 13306 / 16379 — never 80/3306/6379)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
MANIFEST="$REPO/build/dist/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST — run Phase 1 (build/dist) first" >&2; exit 2; }

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-pma.XXXXXX)}"
mkdir -p "$IT"
IT="$(cd "$IT" && pwd -P)"          # /tmp → /private/tmp: executable paths must match RAMP_HOME
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
mkdir -p "$RAMP_HOME" "$RAMP_LOGS" "$IT/sites/p83"

APACHE_PORT="${APACHE_PORT:-18080}" MYSQL_PORT="${MYSQL_PORT:-13306}" REDIS_PORT="${REDIS_PORT:-16379}"
FAILS=0
UP_PID=""
HOME_PAT="${RAMP_HOME#/private}"    # RAMP standardizes /private/tmp → /tmp in argv
PGIDS=""

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

note_pgids() {
    local f
    for f in "$RAMP_HOME"/run/supervisor/*.pid; do [[ -f "$f" ]] && PGIDS="$PGIDS $(cat "$f")"; done
    return 0
}
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

NEWEST="$(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
b = max(m["components"]["php"], key=lambda s: tuple(int(x) for x in s.split(".")))
print(b, m["components"]["php"][b]["version"])
PY
)"
NEWEST_BRANCH="${NEWEST% *}" NEWEST_VERSION="${NEWEST#* }"

echo '<?php echo "p83";' > "$IT/sites/p83/index.php"
/usr/bin/python3 - "$RAMP_HOME/ramp.json" "$IT/sites/p83" <<PY
import json, sys, uuid
out, site = sys.argv[1], sys.argv[2]
cfg = {"schemaVersion": 1,
       "apache": {"port": $APACHE_PORT, "listenAddresses": ["127.0.0.1", "::1"]},
       "mysql": {"port": $MYSQL_PORT, "innodbBufferPoolSize": "256M", "maxAllowedPacket": "64M"},
       "redis": {"port": $REDIS_PORT},
       "hosts": {"defaultTLD": "local", "manageHostsFile": False},
       "vhosts": [{"id": str(uuid.uuid4()), "domain": "p83.t.local", "aliases": [], "docroot": site,
                   "phpBranch": "8.3", "enabled": True}]}
json.dump(cfg, open(out, "w"), indent=2)
PY

echo "== sandbox $IT (apache :$APACHE_PORT, mysql :$MYSQL_PORT)"
echo "== install"
"$RAMPCTL" install --manifest "file://$MANIFEST" | tail -1

echo "== up"
"$RAMPCTL" up > "$IT/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 1500); do
    grep -q -- "--- stack up" "$IT/up.log" 2>/dev/null && break
    kill -0 "$UP_PID" 2>/dev/null || break
    sleep 0.2
done
note_pgids
grep -q -- "--- stack up" "$IT/up.log" || { cat "$IT/up.log"; fail "stack did not come up"; exit 1; }
grep -E "^  (apache|php|mysql)" "$IT/up.log" || true

BASE="http://127.0.0.1:$APACHE_PORT"
JAR="$IT/cookies"
secret() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["phpmyadmin"]["blowfishSecret"])' "$RAMP_HOME/ramp.json"; }
status_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
fmode() { stat -f '%Lp' "$1"; }

PMA="$RAMP_HOME/phpmyadmin/5.2/current"
[[ "$("$RAMPCTL" open phpmyadmin)" == "http://localhost:$APACHE_PORT/phpmyadmin/" ]] \
    && pass "0 rampctl open phpmyadmin → $("$RAMPCTL" open phpmyadmin)" || fail "0 rampctl open phpmyadmin"

# (1) auto-login
code="$(curl -sS -c "$JAR" -b "$JAR" -o "$IT/home.html" -w '%{http_code}' --max-time 30 "$BASE/phpmyadmin/")"
if [[ "$code" == 200 ]] && grep -q "phpMyAdmin" "$IT/home.html" && ! grep -q 'name="pma_username"' "$IT/home.html" \
   && grep -q "route=/server/databases" "$IT/home.html"; then
    pass "1 GET /phpmyadmin/ → 200, logged in (server/databases link, no login form)"
else
    fail "1 GET /phpmyadmin/ → $code"; head -c 2000 "$IT/home.html"; echo
fi
code="$(curl -sS -c "$JAR" -b "$JAR" -o "$IT/dbs.html" -w '%{http_code}' --max-time 30 "$BASE/phpmyadmin/index.php?route=/server/databases")"
if [[ "$code" == 200 ]] && grep -q "information_schema" "$IT/dbs.html" && grep -q "mysql" "$IT/dbs.html"; then
    pass "1 databases list → information_schema, mysql, … shown"
else
    fail "1 databases list → $code"
fi
mysql_ver="$(grep -oE '9\.7\.[0-9]+' "$IT/home.html" | head -1 || true)"
[[ -n "$mysql_ver" ]] && pass "1 home page shows MySQL $mysql_ver (socket connection as root)" || fail "1 MySQL version not on page"

# (2) newest PHP branch
alias_block="$(sed -n '/Alias \/phpmyadmin/,/<\/Directory>/p' "$RAMP_HOME/conf/apache/httpd.conf")"
if grep -q "run/php$NEWEST_BRANCH.sock|" <<<"$alias_block" && grep -qF "$NEWEST_VERSION" "$IT/home.html"; then
    pass "2 alias → php$NEWEST_BRANCH.sock; page reports PHP $NEWEST_VERSION"
else
    fail "2 newest branch $NEWEST_BRANCH ($NEWEST_VERSION) — alias block: $(grep SetHandler <<<"$alias_block")"
fi

# (3) internals denied
for p in setup/ libraries/ templates/ sql/ vendor/ .user.ini; do
    c="$(status_of "$BASE/phpmyadmin/$p")"
    [[ "$c" == 403 ]] && pass "3 /phpmyadmin/$p → 403" || fail "3 /phpmyadmin/$p → $c"
done

# (4) not on project vhosts
c="$(status_of --resolve "p83.t.local:$APACHE_PORT:127.0.0.1" "http://p83.t.local:$APACHE_PORT/phpmyadmin/")"
site="$(curl -s --max-time 10 --resolve "p83.t.local:$APACHE_PORT:127.0.0.1" "http://p83.t.local:$APACHE_PORT/")"
[[ "$c" == 404 && "$site" == p83 ]] && pass "4 p83.t.local/phpmyadmin/ → 404 (site itself serves '$site')" \
    || fail "4 p83.t.local/phpmyadmin/ → $c (site '$site')"
if grep -rqi phpmyadmin "$RAMP_HOME/conf/apache/vhosts/"; then fail "4 phpmyadmin mentioned in vhost files"
else pass "4 no project vhost file mentions phpmyadmin"; fi

# (5) secret stable, file modes, php -l
s1="$(secret)"
"$RAMPCTL" reload >/dev/null
for _ in $(seq 1 100); do grep -q "^reload:" "$IT/up.log" && break; sleep 0.1; done
s2="$(secret)"
[[ ${#s1} == 32 && "$s1" == "$s2" ]] && pass "5 blowfish secret (32 chars) unchanged after rampctl reload" \
    || fail "5 secret '$s1' → '$s2'"
m="$(fmode "$PMA/config.inc.php")"; t="$(fmode "$RAMP_HOME/tmp/phpmyadmin")"
[[ "$m" == 600 && "$t" == 700 ]] && pass "5 config.inc.php mode $m, tmp/phpmyadmin mode $t" || fail "5 modes: config $m, tmp $t"
lint="$("$RAMP_HOME/php/$NEWEST_BRANCH/current/bin/php" -n -l "$PMA/config.inc.php" 2>&1 || true)"
[[ "$lint" == "No syntax errors detected"* ]] && pass "5 php$NEWEST_BRANCH -l config.inc.php: No syntax errors" || fail "5 php -l: $lint"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$BASE/phpmyadmin/")" == 200 ]] && pass "5 still serving after reload" \
    || fail "5 not serving after reload"

# (6) no deprecations / warnings in pages
bad="$(grep -ihoE '(Deprecated|Warning|Notice|Fatal error)(</b>)?:[^<]{0,120}' "$IT/home.html" "$IT/dbs.html" | head -3 || true)"
[[ -z "$bad" ]] && pass "6 no PHP deprecation/warning text in the pages" || fail "6 PHP messages in page: $bad"

# stop → nothing left
note_pgids
kill -TERM "$UP_PID"
for _ in $(seq 1 300); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$UP_PID" 2>/dev/null; then fail "rampctl up did not exit"; fi
UP_PID=""
sleep 0.5
left="$(leftovers)"
if [[ -z "$left" ]]; then pass "SIGTERM rampctl up → no processes left under RAMP_HOME"
else fail "leftovers: $left"; ps -o pid,pgid,command -p "${left// /,}" || true; fi

if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
echo "RESULT: all required checks PASS"
