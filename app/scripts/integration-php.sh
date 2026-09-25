#!/usr/bin/env bash
# PHP management integration test (plan 04-03): installs the real packages from build/dist/manifest.json
# into a throw-away RAMP_HOME, runs `rampctl up` on alternate ports and proves `rampctl php …` on real FPM
# processes: branch-scoped ini changes, reload isolation (other FPM masters + Apache untouched), Xdebug
# toggle, Phalcon defaults, APCu / OPcache clearing, and rejection of invalid changes.
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dir)
#      RAMP_IT_DIR=<existing empty dir, short path — unix sockets are limited to 103 bytes>
#      APACHE_PORT / MYSQL_PORT / REDIS_PORT (defaults 18080 / 13306 / 16379 — never 80/3306/6379)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
MANIFEST="$REPO/build/dist/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST — run Phase 1 (build/dist) first" >&2; exit 2; }

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-php.XXXXXX)}"
mkdir -p "$IT"
IT="$(cd "$IT" && pwd -P)"          # /tmp → /private/tmp: executable paths must match RAMP_HOME
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
mkdir -p "$RAMP_HOME" "$RAMP_LOGS" "$IT/sites"

APACHE_PORT="${APACHE_PORT:-18080}" MYSQL_PORT="${MYSQL_PORT:-13306}" REDIS_PORT="${REDIS_PORT:-16379}"
FAILS=0
UP_PID=""
HOME_PAT="${RAMP_HOME#/private}"    # RAMP standardizes /private/tmp → /tmp in argv
PGIDS=""

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; }
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

# --- branches + one vhost per branch (pNN.t.local) with info.php -----------------------------------
BRANCHES=()
while IFS= read -r line; do BRANCHES+=("$line"); done < <(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for b in sorted(m["components"]["php"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(b)
PY
)
has_branch() { local b; for b in "${BRANCHES[@]}"; do [[ "$b" == "$1" ]] && return 0; done; return 1; }
host_of() { echo "p${1//./}.t.local"; }

for b in "${BRANCHES[@]}"; do
    d="$IT/sites/p${b//./}"
    mkdir -p "$d"
    cat > "$d/info.php" <<'PHP'
<?php header('Content-Type: application/json'); echo json_encode(['v'=>PHP_VERSION,'mem'=>ini_get('memory_limit'),'exec'=>ini_get('max_execution_time'),'post'=>ini_get('post_max_size'),'upl'=>ini_get('upload_max_filesize'),'de'=>ini_get('display_errors'),'tz'=>ini_get('date.timezone'),'xd'=>extension_loaded('xdebug'),'xdm'=>ini_get('xdebug.mode'),'xds'=>ini_get('xdebug.start_with_request'),'apcu'=>extension_loaded('apcu'),'ph'=>extension_loaded('phalcon'),'ext'=>get_loaded_extensions(),'ocs'=>function_exists('opcache_get_status') ? (opcache_get_status(false)['opcache_statistics']['start_time'] ?? null) : null,'apc'=>function_exists('apcu_fetch') ? apcu_fetch('k') : null, 'set'=> isset($_GET['set']) && function_exists('apcu_store') ? apcu_store('k','v') : null]);
PHP
done

/usr/bin/python3 - "$RAMP_HOME/ramp.json" "$IT/sites" "${BRANCHES[@]}" <<PY
import json, sys, uuid
out, sites, branches = sys.argv[1], sys.argv[2], sys.argv[3:]
vhosts = [{"id": str(uuid.uuid4()), "domain": "p%s.t.local" % b.replace(".", ""), "aliases": [],
           "docroot": "%s/p%s" % (sites, b.replace(".", "")), "phpBranch": b, "enabled": True} for b in branches]
cfg = {"schemaVersion": 1,
       "apache": {"port": $APACHE_PORT, "listenAddresses": ["127.0.0.1", "::1"]},
       "mysql": {"port": $MYSQL_PORT, "innodbBufferPoolSize": "256M", "maxAllowedPacket": "64M"},
       "redis": {"port": $REDIS_PORT},
       "services": {"mysql": {"autostart": False}},
       "hosts": {"defaultTLD": "local", "manageHostsFile": False},
       "vhosts": vhosts}
json.dump(cfg, open(out, "w"), indent=2)
PY

echo "== sandbox $IT (apache :$APACHE_PORT)"
echo "== install"
"$RAMPCTL" install --manifest "file://$MANIFEST" | tail -1

pidof_svc() { cat "$RAMP_HOME/run/supervisor/$1.pid" 2>/dev/null || true; }
# info <branch> [query] → JSON (retries while an FPM re-execs after SIGUSR2)
info_json() {
    local h out
    h="$(host_of "$1")"
    for _ in $(seq 1 50); do
        out="$(curl -fsS --max-time 5 --resolve "$h:$APACHE_PORT:127.0.0.1" "http://$h:$APACHE_PORT/info.php${2:-}" 2>/dev/null || true)"
        if [[ "$out" == \{* ]]; then printf '%s' "$out"; return 0; fi
        sleep 0.1
    done
    printf '{}'
}
# field <json> <key> → value as text (true/false/null for JSON literals)
field() {
    /usr/bin/python3 -c 'import json,sys
d=json.loads(sys.argv[1]); v=d.get(sys.argv[2])
print(json.dumps(v) if isinstance(v,(bool,type(None))) else v)' "$1" "$2"
}
fpm_pids() { local b; for b in "${BRANCHES[@]}"; do printf '%s=%s ' "$b" "$(pidof_svc "php$b-fpm")"; done; }
cfg_sum() { shasum -a 256 "$RAMP_HOME/ramp.json" | cut -d' ' -f1; }
php() { "$RAMPCTL" php "$@"; }

echo "== up"
"$RAMPCTL" up > "$IT/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 900); do
    grep -q -- "--- stack up" "$IT/up.log" 2>/dev/null && break
    kill -0 "$UP_PID" 2>/dev/null || break
    sleep 0.2
done
note_pgids
grep -q -- "--- stack up" "$IT/up.log" || { cat "$IT/up.log"; fail "stack did not come up"; exit 1; }
grep -E "^  (apache|php)" "$IT/up.log" || true
php list

# (1) base values identical on every branch
for b in "${BRANCHES[@]}"; do
    j="$(info_json "$b")"
    got="$(field "$j" mem)/$(field "$j" exec)/$(field "$j" post)/$(field "$j" upl)/$(field "$j" de)/$(field "$j" tz)"
    case "$got" in
        "1024M/300/1024M/1024M/1/Europe/Bratislava"|"1024M/300/1024M/1024M/On/Europe/Bratislava")
            pass "1 php $b ($(field "$j" v)) base: $got" ;;
        *) fail "1 php $b base: '$got'" ;;
    esac
done

# (2) branch-scoped ini change: only 8.3 changes, other FPM masters + Apache keep their PID
if has_branch 8.3; then
    before="$(fpm_pids)"; httpd_before="$(pidof_svc apache)"
    php ini set 8.3 memory_limit 2048M
    ok=1
    for b in "${BRANCHES[@]}"; do
        m="$(field "$(info_json "$b")" mem)"
        if [[ "$b" == 8.3 ]]; then [[ "$m" == 2048M ]] || { ok=0; info "8.3 memory_limit=$m"; }
        else [[ "$m" == 1024M ]] || { ok=0; info "$b memory_limit=$m"; }; fi
    done
    after="$(fpm_pids)"; httpd_after="$(pidof_svc apache)"
    reloads="$(grep -c "reloaded" "$IT/up.log" || true)"
    if [[ $ok == 1 && "$before" == "$after" && "$httpd_before" == "$httpd_after" ]]; then
        pass "2 ini set 8.3 memory_limit 2048M → only 8.3 changed; FPM pids unchanged ($after), httpd $httpd_after unchanged"
    else
        fail "2 isolation: ok=$ok fpm '$before' → '$after', httpd $httpd_before → $httpd_after"
    fi
    [[ "$(php ini get 8.3 memory_limit)" == "memory_limit = 2048M  (branch)" ]] && pass "2 ini get shows source=branch" \
        || fail "2 ini get: $(php ini get 8.3 memory_limit)"
else
    skip "2 php 8.3 not installed"
fi

# (3) Xdebug: not loaded anywhere by default; debug on 8.3 only; off again
xd_any=""
for b in "${BRANCHES[@]}"; do [[ "$(field "$(info_json "$b")" xd)" == true ]] && xd_any="$xd_any $b"; done
[[ -z "$xd_any" ]] && pass "3 xdebug not loaded on any branch by default" || fail "3 xdebug loaded on:$xd_any"
if has_branch 8.3; then
    php xdebug 8.3 debug
    j="$(info_json 8.3)"
    others=""
    for b in "${BRANCHES[@]}"; do [[ "$b" != 8.3 && "$(field "$(info_json "$b")" xd)" == true ]] && others="$others $b"; done
    if [[ "$(field "$j" xd)" == true && "$(field "$j" xdm)" == debug && "$(field "$j" xds)" == trigger && -z "$others" ]]; then
        pass "3 xdebug 8.3 debug → loaded on 8.3 only (mode=debug, start_with_request=trigger)"
    else
        fail "3 xdebug debug: 8.3 xd=$(field "$j" xd) mode=$(field "$j" xdm) swr=$(field "$j" xds), others:$others"
    fi
    php xdebug 8.3 off
    [[ "$(field "$(info_json 8.3)" xd)" == false ]] && pass "3 xdebug 8.3 off → unloaded" || fail "3 xdebug still loaded after off"
else
    skip "3 xdebug toggle: php 8.3 not installed"
fi

# (4) Phalcon: default on 8.2 only
if has_branch 8.2; then
    [[ "$(field "$(info_json 8.2)" ph)" == true ]] && pass "4 phalcon loaded on 8.2" || fail "4 phalcon not loaded on 8.2"
else skip "4 phalcon on 8.2: not installed"; fi
if has_branch 8.3; then
    [[ "$(field "$(info_json 8.3)" ph)" == false ]] && pass "4 phalcon not loaded on 8.3" || fail "4 phalcon loaded on 8.3"
fi

# (5) APCu: value stored → present → clear-apcu 8.3 → gone
if has_branch 8.3; then
    info_json 8.3 "?set=1" >/dev/null
    v1="$(field "$(info_json 8.3)" apc)"
    php clear-apcu 8.3
    v2="$(field "$(info_json 8.3)" apc)"
    if [[ "$v1" == v && "$v2" != v ]]; then pass "5 apcu 'k' = $v1 → after clear-apcu: $v2"
    else fail "5 apcu before '$v1' after '$v2'"; fi
else skip "5 apcu: php 8.3 not installed"; fi

# (6) OPcache: start_time changes on 8.3 after clear-opcache, unchanged on 8.2
if has_branch 8.3; then
    s83="$(field "$(info_json 8.3)" ocs)"; s82=""
    has_branch 8.2 && s82="$(field "$(info_json 8.2)" ocs)"
    sleep 1.2                              # start_time has 1 s resolution
    php clear-opcache 8.3
    n83="$(field "$(info_json 8.3)" ocs)"; n82=""
    has_branch 8.2 && n82="$(field "$(info_json 8.2)" ocs)"
    if [[ "$s83" =~ ^[0-9]+$ && "$n83" =~ ^[0-9]+$ && "$n83" -gt "$s83" && "$s82" == "$n82" ]]; then
        pass "6 opcache start_time 8.3 $s83 → $n83, 8.2 unchanged ($n82)"
    else
        fail "6 opcache start_time 8.3 $s83 → $n83, 8.2 $s82 → $n82"
    fi
else skip "6 opcache: php 8.3 not installed"; fi

# (7) protected key → exit 2, config unchanged
if has_branch 8.3; then
    sum="$(cfg_sum)"; set +e; php ini set 8.3 extension foo 2>"$IT/e7"; rc=$?; set -e
    [[ $rc == 2 && "$(cfg_sum)" == "$sum" ]] && pass "7 ini set extension → exit 2 ($(cat "$IT/e7")), ramp.json unchanged" \
        || fail "7 protected key: rc=$rc"
else skip "7 protected key: php 8.3 not installed"; fi

# (8) unavailable extension → exit 2
if has_branch 7.3; then
    sum="$(cfg_sum)"; set +e; php ext 7.3 phalcon on 2>"$IT/e8"; rc=$?; set -e
    [[ $rc == 2 && "$(cfg_sum)" == "$sum" ]] && pass "8 ext 7.3 phalcon on → exit 2 ($(cat "$IT/e8")), ramp.json unchanged" \
        || fail "8 unavailable ext: rc=$rc"
else skip "8 php 7.3 not installed"; fi

# every change so far reloaded single FPMs — Apache never reloaded by `rampctl php`
if grep -q "\[apache\] reloaded" "$IT/up.log"; then fail "apache was reloaded during php changes"
else pass "apache never reloaded (pid $(pidof_svc apache))"; fi

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
