#!/usr/bin/env bash
# End-to-end Elasticsearch test (plan 06-03): installs the official ES 9.5.4 darwin-aarch64 tarball through
# `rampctl es install` into a throw-away RAMP_HOME and runs it under `rampctl up` on alternate ports
# (http 19200, transport 19300 — never 9200/9300, the user's own ES may be running) with a 512m heap.
# Never touches ~/Lib/elasticsearch-9.5.4 or ~/Library/LaunchAgents.
#
# Checks: no autostart, version, explicit heap, loopback-only listeners, single-node/green|yellow/no security,
# persistence in RAMP's data dir, heap change → restart, plugin install (SKIP when offline), crash/orphan
# handling after kill -9 of the launcher, clean shutdown on SIGTERM of `rampctl up`.
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dir)
#      RAMP_IT_DIR=<dir, default mktemp /tmp/ramp-es.XXXXXX; must be empty or a previous run of this script>
#      ES_CACHE_DIR=<dir holding/receiving the ~650 MB tarball, default build/cache>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
DIST_MANIFEST="$REPO/build/dist/manifest.json"
CACHE="${ES_CACHE_DIR:-$REPO/build/cache}"
HTTP_PORT=19200 TRANSPORT_PORT=19300
ES="http://127.0.0.1:$HTTP_PORT"
PY=/usr/bin/python3

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-es.XXXXXX)}"
if [[ -d "$IT" && -n "$(ls -A "$IT" 2>/dev/null)" && ! -f "$IT/.ramp-es-it" ]]; then
    echo "$IT is not empty and not a previous run of this script — refusing" >&2; exit 2
fi
rm -rf "$IT"; mkdir -p "$IT"; touch "$IT/.ramp-es-it"
IT="$(cd "$IT" && pwd -P)"          # /tmp → /private/tmp: the JVM's argv uses the resolved path
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
mkdir -p "$RAMP_HOME/downloads" "$RAMP_LOGS"
# Every ES process (launcher + server JVM) runs from $RAMP_HOME/elasticsearch/…; the launcher's argv uses RAMP's
# /tmp spelling, the server JVM's the resolved /private/tmp one → match the common suffix.
HOME_PAT="${RAMP_HOME#/private}/"
SERVER_PAT="${RAMP_HOME#/private}/.*org.elasticsearch.bootstrap.Elasticsearch"

FAILS=0
UP_PID=""
RESULTS=()
pass() { printf 'PASS  %s\n' "$*"; RESULTS+=("PASS  $*"); }
fail() { printf 'FAIL  %s\n' "$*"; RESULTS+=("FAIL  $*"); FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; RESULTS+=("SKIP  $*"); }
info() { printf 'INFO  %s\n' "$*"; RESULTS+=("INFO  $*"); }

now() { $PY -c 'import time; print(time.time())'; }
since() { $PY -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.1f}s')" "$1" "$(now)"; }
# jget <url> <python expr over d>
jget() { curl -fsS -m 10 "$1" | $PY -c "import sys, json; d = json.load(sys.stdin); print($2)"; }
es_up() { curl -fsS -m 2 "$ES" >/dev/null 2>&1; }
wait_es() {  # wait_es <seconds>
    local end=$(( $(date +%s) + $1 ))
    while (( $(date +%s) < end )); do es_up && return 0; sleep 0.5; done
    return 1
}
es_procs() { pgrep -f "$HOME_PAT" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true; }
server_jvms() { pgrep -f "$SERVER_PAT" 2>/dev/null | wc -l | tr -d ' '; }
launcher_pid() { cat "$RAMP_HOME/run/supervisor/elasticsearch.pid" 2>/dev/null || true; }
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

cleanup() {
    local rc=$?
    if [[ -n "$UP_PID" ]] && kill -0 "$UP_PID" 2>/dev/null; then
        kill -TERM "$UP_PID" 2>/dev/null || true
        for _ in $(seq 1 200); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
    fi
    local left
    left="$(es_procs)"
    if [[ -n "$left" ]]; then
        echo "cleanup: killing leftover processes: $left" >&2
        kill -9 $left 2>/dev/null || true
    fi
    if [[ "${KEEP:-0}" != 1 ]]; then rm -rf "$IT"; else echo "kept $IT" >&2; fi
    exit $rc
}
trap cleanup EXIT INT TERM

for p in $HTTP_PORT $TRANSPORT_PORT; do
    if port_busy "$p"; then echo "port $p is in use — refusing to run" >&2; exit 2; fi
done

# --- rampctl -------------------------------------------------------------------------------------
if [[ -z "${RAMPCTL:-}" ]]; then
    SCRATCH_ARGS=()
    [[ -n "${SWIFT_SCRATCH:-}" ]] && SCRATCH_ARGS=(--scratch-path "$SWIFT_SCRATCH")
    swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --product rampctl >/dev/null
    RAMPCTL="$(swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --show-bin-path)/rampctl"
fi

# --- manifest (ES entry only: `rampctl up` then has nothing else to install) + cached tarball -------
MANIFEST="$IT/manifest.json"
$PY - "$DIST_MANIFEST" "$MANIFEST" <<'PY'
import json, os, sys, urllib.request
src, dst = sys.argv[1], sys.argv[2]
entry = None
if os.path.exists(src):
    entry = json.load(open(src)).get("components", {}).get("elasticsearch", {}).get("9.5")
if entry is None:   # 01-07 not executed: official URL + official .sha512 (real package, not faked)
    url = "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.5.4-darwin-aarch64.tar.gz"
    sha = urllib.request.urlopen(url + ".sha512", timeout=30).read().decode().split()[0]
    entry = {"version": "9.5.4", "url": url, "sha512": sha}
json.dump({"schema": 1, "generated": "integration-elasticsearch", "components": {"elasticsearch": {"9.5": entry}}},
          open(dst, "w"), indent=1)
PY
read -r ES_URL ES_SHA ES_VERSION < <($PY -c 'import json,sys; e=json.load(open(sys.argv[1]))["components"]["elasticsearch"]["9.5"]; print(e["url"], e["sha512"], e["version"])' "$MANIFEST")
TARBALL="$(basename "$ES_URL")"
mkdir -p "$CACHE"
if [[ ! -f "$CACHE/$TARBALL" ]] || [[ "$(shasum -a 512 "$CACHE/$TARBALL" | awk '{print $1}')" != "$ES_SHA" ]]; then
    info "downloading $ES_URL into $CACHE"
    curl -fsSL -o "$CACHE/$TARBALL.part" "$ES_URL"
    mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
# Pre-seed the installer's download cache (it still verifies size + sha512).
ln "$CACHE/$TARBALL" "$RAMP_HOME/downloads/$TARBALL" 2>/dev/null || cp -c "$CACHE/$TARBALL" "$RAMP_HOME/downloads/$TARBALL" 2>/dev/null \
    || cp "$CACHE/$TARBALL" "$RAMP_HOME/downloads/$TARBALL"

cat > "$RAMP_HOME/ramp.json" <<JSON
{
  "schemaVersion": 1,
  "manifestURL": "file://$MANIFEST",
  "elasticsearch": { "branch": "9.5", "httpPort": $HTTP_PORT, "transportPort": $TRANSPORT_PORT,
                     "bindAddress": "127.0.0.1", "heap": "512m", "plugins": [] }
}
JSON

# --- install ---------------------------------------------------------------------------------------
t0=$(now)
if "$RAMPCTL" es install > "$IT/install.out" 2>&1; then
    info "rampctl es install: $(since "$t0") ($(tail -1 "$IT/install.out"))"
else
    cat "$IT/install.out" >&2; fail "rampctl es install"; exit 1
fi

# --- (1) rampctl up never starts ES ------------------------------------------------------------------
"$RAMPCTL" up > "$IT/up.out" 2>&1 &
UP_PID=$!
for _ in $(seq 1 100); do [[ -f "$RAMP_HOME/run/rampctl.pid" ]] && break; sleep 0.2; done
sleep 20
if ! port_busy $HTTP_PORT && ! es_up && [[ -z "$(es_procs)" ]]; then
    pass "(1) rampctl up: nothing on :$HTTP_PORT after 20 s, no ES process (never autostarts)"
else
    fail "(1) ES is running after rampctl up"
fi

# --- (2) es start → version ------------------------------------------------------------------------
t0=$(now)
"$RAMPCTL" es start > "$IT/start.out" 2>&1 || true
if wait_es 120; then
    COLD_START="$(since "$t0")"
    v="$(jget "$ES" 'd["version"]["number"]')"
    if [[ "$v" == "$ES_VERSION" ]]; then pass "(2) es start → $ES answers, version $v (cold start $COLD_START)"
    else fail "(2) version $v != $ES_VERSION"; fi
else
    cat "$IT/start.out" >&2; tail -30 "$RAMP_LOGS/elasticsearch/elasticsearch.log" >&2 2>/dev/null || true
    fail "(2) ES did not answer within 120 s"; exit 1
fi

# --- (3) heap --------------------------------------------------------------------------------------
heap_of() { jget "$ES/_nodes/jvm" 'list(d["nodes"].values())[0]["jvm"]["mem"]["'"$1"'"]'; }
hmax="$(heap_of heap_max_in_bytes)"; hinit="$(heap_of heap_init_in_bytes)"
if [[ "$hmax" == 536870912 && "$hinit" == "$hmax" ]]; then pass "(3) heap_max = heap_init = 512 MiB"
else fail "(3) heap_max=$hmax heap_init=$hinit"; fi

# --- (4) loopback-only listeners ---------------------------------------------------------------------
listen_ok() {
    local addrs
    addrs="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u | tr '\n' ' ')"
    [[ -n "$addrs" ]] || { echo "none"; return 1; }
    echo "$addrs"
    ! grep -qvE '^127\.0\.0\.1:' <<< "$(tr ' ' '\n' <<< "$addrs" | sed '/^$/d')"
}
a1="$(listen_ok $HTTP_PORT)" && r1=0 || r1=1
a2="$(listen_ok $TRANSPORT_PORT)" && r2=0 || r2=1
if (( r1 == 0 && r2 == 0 )); then pass "(4) listeners: $a1/ $a2(127.0.0.1 only)"
else fail "(4) listeners: http [$a1] transport [$a2]"; fi

# --- (5) health, single-node, security off ------------------------------------------------------------
health="$(jget "$ES/_cluster/health" 'd["status"]')"
dtype="$(jget "$ES/_nodes/settings" 'list(d["nodes"].values())[0]["settings"]["discovery"]["type"]')"
sec="$(jget "$ES/_xpack" 'd["features"]["security"]["enabled"]')"
if [[ "$health" =~ ^(green|yellow)$ && "$dtype" == single-node && "$sec" == False ]]; then
    pass "(5) health $health, discovery.type $dtype, security disabled (plain HTTP, no auth)"
else fail "(5) health=$health discovery=$dtype security=$sec"; fi

# --- (6) persistence + RAMP data dir ----------------------------------------------------------------------
curl -fsS -m 10 -X PUT "$ES/ramp-it/_doc/1?refresh=true" -H 'Content-Type: application/json' -d '{"k":"persist"}' >/dev/null
t0=$(now)
"$RAMPCTL" es stop > "$IT/stop.out" 2>&1 || true
STOP_TIME="$(since "$t0")"
stopped_ok=0; es_up || [[ -n "$(es_procs)" ]] || stopped_ok=1
t0=$(now)
"$RAMPCTL" es start > "$IT/start2.out" 2>&1 || true
wait_es 120 || true
WARM_START="$(since "$t0")"
# The shard is allocated shortly after the HTTP port opens (503 until then).
curl -fsS -m 70 "$ES/_cluster/health/ramp-it?wait_for_status=yellow&timeout=60s" >/dev/null 2>&1 || true
found="$(jget "$ES/ramp-it/_doc/1" 'd["found"] and d["_source"]["k"]' 2>/dev/null || echo error)"
PKG_DIR="$(cd "$RAMP_HOME/elasticsearch/9.5/current" && pwd -P)"
data_files="$(find "$RAMP_HOME/elasticsearch-data/9.5" -type f 2>/dev/null | wc -l | tr -d ' ')"
pkg_written="$( { find "$PKG_DIR/data" -mindepth 1 2>/dev/null; find "$PKG_DIR/logs" -mindepth 1 2>/dev/null; } | wc -l | tr -d ' ')"
if [[ "$stopped_ok" == 1 && "$found" == persist && "$data_files" -gt 0 && "$pkg_written" == 0 ]]; then
    pass "(6) doc survives stop ($STOP_TIME)/start ($WARM_START); $data_files files in elasticsearch-data/9.5; package data/ + logs/ untouched"
else fail "(6) stopped=$stopped_ok found=$found data_files=$data_files package_writes=$pkg_written"; fi

# --- (7) heap change while running → restart -----------------------------------------------------------
old_launcher="$(launcher_pid)"
t0=$(now)
"$RAMPCTL" es heap 768m > "$IT/heap.out" 2>&1 || true
wait_es 120 || true
hmax="$(heap_of heap_max_in_bytes 2>/dev/null || echo error)"
if [[ "$hmax" == 805306368 && "$(launcher_pid)" != "$old_launcher" ]]; then
    pass "(7) es heap 768m → restarted ($(since "$t0")), heap_max = 768 MiB"
else cat "$IT/heap.out" >&2; fail "(7) heap_max=$hmax launcher $old_launcher → $(launcher_pid)"; fi

# --- (8) plugins ----------------------------------------------------------------------------------------
if curl -fsSI -m 10 https://artifacts.elastic.co/ >/dev/null 2>&1; then
    t0=$(now)
    if "$RAMPCTL" es plugin install analysis-icu > "$IT/plugin.out" 2>&1 \
        && "$RAMPCTL" es restart > "$IT/restart.out" 2>&1 && wait_es 120 \
        && curl -fsS -m 10 "$ES/_cat/plugins?h=component" | grep -qx analysis-icu; then
        pass "(8) plugin analysis-icu installed + restart → listed in _cat/plugins ($(since "$t0"))"
    else cat "$IT/plugin.out" "$IT/restart.out" >&2 2>/dev/null || true; fail "(8) analysis-icu"; fi
else
    skip "(8) plugin install: artifacts.elastic.co unreachable (offline)"
fi
set +e; "$RAMPCTL" es plugin install ../x > "$IT/badplugin.out" 2>&1; rc=$?; set -e
if [[ $rc == 2 ]]; then pass "(8b) invalid plugin name ../x → exit 2 ($(head -1 "$IT/badplugin.out"))"
else fail "(8b) invalid plugin name exit $rc"; fi

# --- (9) crash / orphan: kill -9 the launcher ---------------------------------------------------------------
launcher="$(launcher_pid)"
old_server="$(pgrep -f "$SERVER_PAT" | head -1 || true)"
t0=$(now)
kill -9 "$launcher"
recovered=0
for _ in $(seq 1 360); do
    new="$(launcher_pid)"
    if [[ -n "$new" && "$new" != "$launcher" ]] && es_up; then recovered=1; break; fi
    sleep 0.5
done
jvms="$(server_jvms)"
if [[ $recovered == 1 && "$jvms" == 1 ]] && ! kill -0 "$old_server" 2>/dev/null; then
    pass "(9) kill -9 launcher → supervisor restarted ES ($(since "$t0")), exactly 1 server JVM, old JVM gone"
else fail "(9) recovered=$recovered server_jvms=$jvms old_server_alive=$(kill -0 "$old_server" 2>/dev/null && echo yes || echo no)"; fi

# --- (10) SIGTERM rampctl up → ES stopped ---------------------------------------------------------------------
t0=$(now)
kill -TERM "$UP_PID"
gone=0
for _ in $(seq 1 175); do
    if ! kill -0 "$UP_PID" 2>/dev/null && [[ -z "$(es_procs)" ]]; then gone=1; break; fi
    sleep 0.2
done
if [[ $gone == 1 ]]; then pass "(10) SIGTERM rampctl up → ES + up gone in $(since "$t0") (≤ 35 s), no java under RAMP_HOME"; UP_PID=""
else fail "(10) after 35 s: up alive=$(kill -0 "$UP_PID" 2>/dev/null && echo yes || echo no), processes: $(es_procs)"; fi

echo
echo "=== summary ==="
printf '%s\n' "${RESULTS[@]}"
echo "timings: cold start $COLD_START, stop $STOP_TIME, warm start $WARM_START"
if (( FAILS > 0 )); then echo "$FAILS check(s) FAILED"; exit 1; fi
echo "all checks passed"
