#!/usr/bin/env bash
# End-to-end update test (plan 07-02): Redis only, in a throw-away RAMP_HOME on alternate ports.
#   v1 (build/dist Redis) install + `rampctl up`
#   v2 = repacked copy with a bumped version (same binaries)      → update, current flips, PING, previousVersion
#   v3 = package whose bin/redis-server exits 1 (sanity file ok)  → update rolls back, current stays v2, PING
#   v4 = checksum mismatch                                        → nothing changes, Redis never stopped
#   rampctl update rollback                                       → back to v1, PING
# Never touches :80/:3306/:6379 or the real Application Support.
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dir)
#      RAMP_IT_DIR=<empty dir, short path>   APACHE_PORT / MYSQL_PORT / REDIS_PORT (default 18080/13306/16379)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
DIST="$REPO/build/dist"
MANIFEST="$DIST/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    echo "SKIP  missing $MANIFEST — run Phase 1 (build/dist) first" >&2
    exit 2
fi

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-upd.XXXXXX)}"
mkdir -p "$IT"
IT="$(cd "$IT" && pwd -P)"          # /tmp → /private/tmp: executable paths must match RAMP_HOME
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
mkdir -p "$RAMP_HOME" "$RAMP_LOGS"

APACHE_PORT="${APACHE_PORT:-18080}" MYSQL_PORT="${MYSQL_PORT:-13306}" REDIS_PORT="${REDIS_PORT:-16379}"
FAILS=0
UP_PID=""
HOME_PAT="${RAMP_HOME#/private}"
PGIDS=""

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

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

# --- manifests -----------------------------------------------------------------------------------
read -r BRANCH V1 V1FILE < <(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["components"]["redis"]
b = sorted(m, key=lambda s: tuple(int(x) for x in s.split(".")))[-1]
print(b, m[b]["version"], m[b]["url"].rsplit("/", 1)[-1])
PY
)
V2="$BRANCH.99" V3="$BRANCH.100" V4="$BRANCH.101"

# write_manifest <dir> <version> <archive> [sha-override]
write_manifest() {
    /usr/bin/python3 - "$@" <<'PY'
import hashlib, json, os, sys
d, version, archive = sys.argv[1], sys.argv[2], sys.argv[3]
sha = sys.argv[4] if len(sys.argv) > 4 else hashlib.sha256(open(archive, "rb").read()).hexdigest()
branch = ".".join(version.split(".")[:2])
entry = {"version": version, "url": "${RAMP_DIST_BASE}/" + os.path.basename(archive), "sha256": sha,
         "size": os.path.getsize(archive), "file": os.path.basename(archive)}
json.dump({"schema": 1, "generated": "2026-09-25T00:00:00Z", "components": {"redis": {branch: entry}}},
          open(os.path.join(d, "manifest.json"), "w"), indent=1)
PY
}

# repack <version> <dir> [broken]: build/dist Redis tree renamed to redis-<version>/ (optionally broken server)
repack() {
    local version="$1" out="$2" broken="${3:-}" work="$IT/work-$1"
    mkdir -p "$work" "$out"
    tar -xJf "$DIST/$V1FILE" -C "$work"
    local top; top="$(ls "$work")"
    mv "$work/$top" "$work/redis-$version"
    if [[ -n "$broken" ]]; then
        printf '#!/bin/sh\necho "broken redis-server %s" >&2\nexit 1\n' "$version" > "$work/redis-$version/bin/redis-server"
        chmod 755 "$work/redis-$version/bin/redis-server"
    fi
    tar -cJf "$out/redis-$version-darwin-arm64.tar.xz" -C "$work" "redis-$version"
    rm -rf "$work"
    echo "$out/redis-$version-darwin-arm64.tar.xz"
}

M1="$IT/m1" M2="$IT/m2" M3="$IT/m3" M4="$IT/m4"
mkdir -p "$M1"
cp "$DIST/$V1FILE" "$M1/"
write_manifest "$M1" "$V1" "$M1/$V1FILE"
write_manifest "$M2" "$V2" "$(repack "$V2" "$M2")"
write_manifest "$M3" "$V3" "$(repack "$V3" "$M3" broken)"
A4="$(repack "$V4" "$M4")"
write_manifest "$M4" "$V4" "$A4" "$(printf '0%.0s' $(seq 1 64))"

cat > "$RAMP_HOME/ramp.json" <<JSON
{"schemaVersion": 1,
 "apache": {"port": $APACHE_PORT, "listenAddresses": ["127.0.0.1"]},
 "mysql": {"port": $MYSQL_PORT},
 "redis": {"port": $REDIS_PORT}}
JSON

REDIS_CLI() { "$RAMP_HOME/redis/$BRANCH/current/bin/redis-cli" -h 127.0.0.1 -p "$REDIS_PORT" "$@" 2>&1; }
current() { readlink "$RAMP_HOME/redis/$BRANCH/current"; }
redis_pid() { cat "$RAMP_HOME/run/supervisor/redis.pid" 2>/dev/null || true; }
record() {  # record <field>
    /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["installed"]["redis"][sys.argv[2]]; print(r.get(sys.argv[3]) or "")' \
        "$RAMP_HOME/ramp.json" "$BRANCH" "$1"
}
wait_ping() { for _ in $(seq 1 75); do [[ "$(REDIS_CLI PING)" == PONG ]] && return 0; sleep 0.2; done; return 1; }

echo "== sandbox $IT (redis $BRANCH: v1 $V1, v2 $V2, v3 $V3 broken, v4 $V4 bad checksum; port $REDIS_PORT)"
"$RAMPCTL" install --manifest "file://$M1/manifest.json"
check "v1 installed, current → ../$V1" test "$(current)" == "../$V1"

"$RAMPCTL" up > "$IT/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 100); do [[ -f "$RAMP_HOME/run/rampctl.pid" && -n "$(redis_pid)" ]] && break; sleep 0.2; done
check "rampctl up: redis PONG" wait_ping
note_pgids

echo "== check"
"$RAMPCTL" update check --manifest "file://$M2/manifest.json" | tee "$IT/check.out"
check "update check lists redis $V1 → $V2 (offered)" grep -Eq "offered +redis +$BRANCH +$V1 +$V2" "$IT/check.out"

echo "== v2: update"
PID_BEFORE="$(redis_pid)"
set +e; "$RAMPCTL" update apply redis "$BRANCH" --manifest "file://$M2/manifest.json" | tee "$IT/v2.out"; RC=${PIPESTATUS[0]}; set -e
note_pgids
check "v2 apply exit 0" test "$RC" -eq 0
check "v2 current → ../$V2" test "$(current)" == "../$V2"
check "v2 redis PONG" wait_ping
check "v2 redis restarted (new pid)" test "$(redis_pid)" != "$PID_BEFORE"
check "v2 ramp.json version $V2, previousVersion $V1" test "$(record version) $(record previousVersion)" == "$V2 $V1"
check "v2 previous dir $V1 kept" test -x "$RAMP_HOME/redis/$V1/bin/redis-server"

echo "== v3: broken package → rollback"
set +e; "$RAMPCTL" update apply redis "$BRANCH" --manifest "file://$M3/manifest.json" | tee "$IT/v3.out"; RC=${PIPESTATUS[0]}; set -e
note_pgids
check "v3 apply exit 1 (rolled back)" test "$RC" -eq 1
check "v3 outcome says rolled back to $V2" grep -q "rolled back to $V2" "$IT/v3.out"
check "v3 current → ../$V2" test "$(current)" == "../$V2"
check "v3 redis PONG after rollback" wait_ping
check "v3 ramp.json still $V2 (previous $V1)" test "$(record version) $(record previousVersion)" == "$V2 $V1"
check "v3 broken dir kept for diagnosis" test -d "$RAMP_HOME/redis/$V3"

echo "== v4: checksum mismatch"
PID_BEFORE="$(redis_pid)"
JSON_BEFORE="$(shasum -a 256 "$RAMP_HOME/ramp.json")"
set +e; "$RAMPCTL" update apply redis "$BRANCH" --manifest "file://$M4/manifest.json" | tee "$IT/v4.out"; RC=${PIPESTATUS[0]}; set -e
check "v4 apply exit 2" test "$RC" -eq 2
check "v4 reports checksum mismatch" grep -qi "checksum" "$IT/v4.out"
check "v4 current unchanged ../$V2" test "$(current)" == "../$V2"
check "v4 redis never stopped (same pid)" test "$(redis_pid)" == "$PID_BEFORE"
check "v4 ramp.json unchanged" test "$(shasum -a 256 "$RAMP_HOME/ramp.json")" == "$JSON_BEFORE"
check "v4 no version dir extracted" test ! -e "$RAMP_HOME/redis/$V4"

echo "== manual rollback"
set +e; "$RAMPCTL" update rollback redis "$BRANCH" | tee "$IT/rb.out"; RC=${PIPESTATUS[0]}; set -e
note_pgids
check "rollback exit 0" test "$RC" -eq 0
check "rollback current → ../$V1" test "$(current)" == "../$V1"
check "rollback redis PONG" wait_ping
check "rollback ramp.json $V1 (previous $V2)" test "$(record version) $(record previousVersion)" == "$V1 $V2"

echo "== stop"
kill -TERM "$UP_PID"
for _ in $(seq 1 150); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
UP_PID=""
check "no sandbox processes left" test -z "$(leftovers)"

echo "== $([[ $FAILS -eq 0 ]] && echo "ALL PASS" || echo "$FAILS FAILED")"
[[ $FAILS -eq 0 ]]
