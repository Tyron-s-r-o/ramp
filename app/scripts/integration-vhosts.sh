#!/usr/bin/env bash
# End-to-end vhost test (plan 03-05): throw-away RAMP_HOME, `rampctl up` on an alternate Apache port
# (never 80), vhosts added/changed/removed through `rampctl vhost …` while the stack runs.
# Checks per-vhost PHP branch, alias, .htaccess rewrite, Authorization header, IPv4 + IPv6
# (`curl --resolve`, no /etc/hosts), validation failures leave ramp.json untouched, Apache rejection
# rolls back, disable prunes the vhost file, graceful reload only (Apache + FPM PIDs unchanged), and
# hosts-block sync against a TEMP hosts file (RAMP_HOSTS_FILE) — the real /etc/hosts is only read.
#
# Env: RAMPCTL=<prebuilt rampctl>   SWIFT_SCRATCH=<swift build --scratch-path>   KEEP=1 (keep temp dirs)
#      RAMP_IT_DIR=<empty dir, short path — unix sockets ≤ 103 bytes>   APACHE_PORT (default 18080)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
PKG="$REPO/app/Packages/RAMPCore"
MANIFEST="$REPO/build/dist/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST — run Phase 1 (build/dist) first" >&2; exit 2; }

IT="${RAMP_IT_DIR:-$(mktemp -d /tmp/ramp-vh.XXXXXX)}"
mkdir -p "$IT"
IT="$(cd "$IT" && pwd -P)"
export RAMP_HOME="$IT/home" RAMP_LOGS="$IT/logs"
unset RAMP_HOSTS_FILE
mkdir -p "$RAMP_HOME" "$RAMP_LOGS"
# Docroots must not live under /private (validator forbids system dirs; /tmp resolves to /private/tmp).
SITES="$(mktemp -d "$HOME/.ramp-it-sites.XXXXXX")"

APACHE_PORT="${APACHE_PORT:-18080}"
FAILS=0
UP_PID=""
HOME_PAT="${RAMP_HOME#/private}"
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
    if [[ -n "$left" ]]; then echo "cleanup: killing leftover processes: $left" >&2; kill -9 $left 2>/dev/null || true; fi
    if [[ "${KEEP:-0}" != 1 ]]; then rm -rf "$IT" "$SITES"; else echo "kept $IT $SITES" >&2; fi
    exit $rc
}
trap cleanup EXIT INT TERM

if [[ -z "${RAMPCTL:-}" ]]; then
    SCRATCH_ARGS=()
    [[ -n "${SWIFT_SCRATCH:-}" ]] && SCRATCH_ARGS=(--scratch-path "$SWIFT_SCRATCH")
    swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --product rampctl >/dev/null
    RAMPCTL="$(swift build --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --show-bin-path)/rampctl"
fi

# --- docroots --------------------------------------------------------------------------------------
for d in a83 a82; do
    mkdir -p "$SITES/$d"
    printf '<?php echo "PHPV=" . PHP_VERSION . " AUTH=" . ($_SERVER["HTTP_AUTHORIZATION"] ?? "") . " R=" . ($_GET["r"] ?? "");\n' \
        > "$SITES/$d/index.php"
    printf 'RewriteEngine On\nRewriteRule ^pretty/?$ index.php?r=rewritten [L,QSA]\n' > "$SITES/$d/.htaccess"
done

# Only Apache + FPM needed: MySQL/Redis off (alternate ports anyway), hosts file not managed.
/usr/bin/python3 - "$RAMP_HOME/ramp.json" <<PY
import json, sys
json.dump({"schemaVersion": 1,
           "apache": {"port": $APACHE_PORT, "listenAddresses": ["127.0.0.1", "::1"]},
           "mysql": {"port": 13307}, "redis": {"port": 16380},
           "services": {"mysql": {"autostart": False}, "redis": {"autostart": False}},
           "hosts": {"manageHostsFile": False}}, open(sys.argv[1], "w"), indent=2)
PY

echo "== sandbox $IT (sites $SITES, apache :$APACHE_PORT)"
"$RAMPCTL" install --manifest "file://$MANIFEST" | tail -1

V83="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["php"]["8.3"]["version"])' "$MANIFEST")"
V82="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["php"]["8.2"]["version"])' "$MANIFEST")"

pidof_svc() { cat "$RAMP_HOME/run/supervisor/$1.pid" 2>/dev/null || true; }
fpm_pids() { for f in "$RAMP_HOME"/run/supervisor/php*-fpm.pid; do printf '%s ' "$(cat "$f")"; done; }
cfg_sum() { shasum "$RAMP_HOME/ramp.json" | cut -d' ' -f1; }
# get <host> <addr 127.0.0.1|[::1]> [path] [curl args…]
get() {
    local host="$1" addr="$2" path="${3:-}"; shift 3 || shift $#
    curl -sS --max-time 5 --resolve "$host:$APACHE_PORT:$addr" "$@" "http://$host:$APACHE_PORT/$path" 2>&1 || true
}
# wait_for <expected substring> <host> <addr> [path] — graceful reload is asynchronous
wait_for() {
    local want="$1" host="$2" addr="$3" path="${4:-}" body=""
    for _ in $(seq 1 50); do
        body="$(get "$host" "$addr" "$path")"
        [[ "$body" == *"$want"* ]] && { printf '%s' "$body"; return 0; }
        sleep 0.2
    done
    printf '%s' "$body"; return 1
}

echo "== up"
"$RAMPCTL" up > "$IT/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 900); do
    grep -q -- "--- stack up" "$IT/up.log" 2>/dev/null && break
    kill -0 "$UP_PID" 2>/dev/null || break
    sleep 0.2
done
note_pgids
grep -q -- "--- stack up (all services running)" "$IT/up.log" || { cat "$IT/up.log"; fail "stack did not come up cleanly"; }
HTTPD0="$(pidof_svc apache)"; FPM0="$(fpm_pids)"
info "apache pid $HTTPD0, fpm pids $FPM0"

# (1) add vhosts via rampctl
"$RAMPCTL" vhost add a83.test.local "$SITES/a83" --php 8.3 --alias b83.test.local && pass "1 vhost add a83 (8.3, alias b83)" || fail "1 vhost add a83"
"$RAMPCTL" vhost add a82.test.local "$SITES/a82" --php 8.2 && pass "1 vhost add a82 (8.2)" || fail "1 vhost add a82"
"$RAMPCTL" vhost list

# (2) PHP branch per vhost, IPv4 + IPv6
for addr in 127.0.0.1 '[::1]'; do
    b="$(wait_for "PHPV=$V83" a83.test.local "$addr")" && pass "2 a83.test.local via $addr → ${b%% AUTH*}" || fail "2 a83 via $addr → '$b'"
    b="$(wait_for "PHPV=$V82" a82.test.local "$addr")" && pass "2 a82.test.local via $addr → ${b%% AUTH*}" || fail "2 a82 via $addr → '$b'"
    b="$(wait_for "PHPV=$V83" b83.test.local "$addr")" && pass "3 alias b83.test.local via $addr → ${b%% AUTH*}" || fail "3 alias via $addr → '$b'"
done

# (4) .htaccess rewrite, (5) Authorization header reaches PHP (CGIPassAuth)
b="$(get a83.test.local 127.0.0.1 pretty)"
[[ "$b" == *"R=rewritten"* ]] && pass "4 rewrite /pretty → $b" || fail "4 rewrite → '$b'"
b="$(get a82.test.local '[::1]' '' -H 'Authorization: Bearer s3cr3t')"
[[ "$b" == *"AUTH=Bearer s3cr3t"* ]] && pass "5 Authorization header echoed ($b)" || fail "5 Authorization → '$b'"

# (6) invalid adds → non-zero exit, ramp.json untouched
sum="$(cfg_sum)"
if "$RAMPCTL" vhost add c.test.local "$SITES/a83" --alias b83.test.local 2>"$IT/err1"; then fail "6 duplicate alias accepted"
else [[ "$(cfg_sum)" == "$sum" ]] && pass "6 duplicate alias rejected: $(head -1 "$IT/err1")" || fail "6 duplicate alias changed ramp.json"; fi
if "$RAMPCTL" vhost add d.test.local "$SITES/missing" 2>"$IT/err2"; then fail "6 missing docroot accepted"
else [[ "$(cfg_sum)" == "$sum" ]] && pass "6 missing docroot rejected: $(head -1 "$IT/err2")" || fail "6 missing docroot changed ramp.json"; fi

# (7) Apache rejects the config (module removed from the sandbox package) → rollback, Apache keeps serving
MOD="$RAMP_HOME/apache/2.4/current/modules/mod_rewrite.so"
mv "$MOD" "$MOD.off"
if "$RAMPCTL" vhost add e.test.local "$SITES/a82" --php 8.2 2>"$IT/err3"; then fail "7 add accepted with broken Apache config"
else
    if [[ "$(cfg_sum)" == "$sum" && ! -e "$RAMP_HOME/conf/apache/vhosts/e.test.local.conf" ]] \
       && grep -q "rolled back" "$IT/err3" && [[ "$(pidof_svc apache)" == "$HTTPD0" ]] \
       && [[ "$(get a83.test.local 127.0.0.1)" == *"PHPV=$V83"* ]]; then
        pass "7 httpd -t failure → rolled back (ramp.json + vhost files unchanged, Apache $HTTPD0 still serving)"
    else fail "7 rollback: $(head -3 "$IT/err3")"; fi
fi
mv "$MOD.off" "$MOD"

# (8) hosts block sync against a TEMP copy of /etc/hosts (read-only use of the real file)
HOSTS="$IT/hosts"
cp /private/etc/hosts "$HOSTS"; chmod 0644 "$HOSTS"
/usr/bin/python3 - "$RAMP_HOME/ramp.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["hosts"]["manageHostsFile"] = True; json.dump(c, open(sys.argv[1], "w"), indent=2)
PY
RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" hosts status >/dev/null && fail "8 status in sync before sync" || true
out="$(RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" hosts sync)"
block="$(sed -n '/^# RAMP BEGIN/,/^# RAMP END/p' "$HOSTS")"
want=$'127.0.0.1\ta82.test.local\n::1\ta82.test.local\n127.0.0.1\ta83.test.local\n::1\ta83.test.local\n127.0.0.1\tb83.test.local\n::1\tb83.test.local'
if [[ "$out" == *"updated (direct)"* && "$block" == *"$want"* ]] \
   && diff <(/usr/bin/python3 -c 'import sys; s=open(sys.argv[1]).read(); i=s.find("\n\n# RAMP BEGIN"); print(s[:i+1] if i>=0 else s, end="")' "$HOSTS") /private/etc/hosts >/dev/null; then
    pass "8 hosts sync → RAMP block (127.0.0.1 + ::1 per name), rest of file byte-identical"
else fail "8 hosts sync: '$out' block: $block"; fi
RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" hosts status >/dev/null && pass "8 hosts status: in sync" || fail "8 hosts status not in sync"
out="$(RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" hosts sync)"
[[ "$out" == *"already in sync"* ]] && pass "8 second sync is a no-op" || fail "8 second sync: $out"

# (9) disable → default site, vhost file pruned, hosts block updated
out="$(RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" vhost disable a82.test.local)" || fail "9 disable failed"
sleep 0.5
b="$(wait_for "PHP Version" a82.test.local 127.0.0.1)" || true
if [[ "$b" != *"PHPV="* && ! -e "$RAMP_HOME/conf/apache/vhosts/a82.test.local.conf" ]]; then
    pass "9 disable a82 → default site served, a82.test.local.conf pruned"
else fail "9 disable: body '${b:0:80}'"; fi
[[ "$out" == *"hosts: updated (direct)"* ]] && ! grep -q "a82.test.local" "$HOSTS" && pass "9 hosts block without a82" || fail "9 hosts after disable: $out"
RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" vhost enable a82.test.local >/dev/null
b="$(wait_for "PHPV=$V82" a82.test.local '[::1]')" && pass "9 re-enable a82 → $b" || fail "9 re-enable → '$b'"

# (10) remove all → files pruned, hosts block removed, file identical to the original
RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" vhost rm a82.test.local >/dev/null && RAMP_HOSTS_FILE="$HOSTS" "$RAMPCTL" vhost rm b83.test.local >/dev/null \
    || fail "10 rm failed"
if [[ -z "$(ls "$RAMP_HOME/conf/apache/vhosts")" ]] && cmp -s "$HOSTS" /private/etc/hosts \
   && [[ "$("$RAMPCTL" vhost list)" == "" ]]; then
    pass "10 rm (by alias too) → no vhost files, hosts file back to the original bytes"
else fail "10 rm: $(ls "$RAMP_HOME/conf/apache/vhosts") / cmp $(cmp "$HOSTS" /private/etc/hosts 2>&1)"; fi

# (11) graceful only
[[ "$(pidof_svc apache)" == "$HTTPD0" ]] && pass "11 Apache pid unchanged ($HTTPD0) after all changes" || fail "11 apache pid $HTTPD0 → $(pidof_svc apache)"
[[ "$(fpm_pids)" == "$FPM0" ]] && pass "11 FPM pids unchanged" || fail "11 fpm pids '$FPM0' → '$(fpm_pids)'"
n="$(grep -c "AH00493: SIGUSR1 received" "$RAMP_LOGS"/apache*error*.log 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
info "graceful restarts logged by httpd: $n"

# stop → nothing left
kill -TERM "$UP_PID"
for _ in $(seq 1 300); do kill -0 "$UP_PID" 2>/dev/null || break; sleep 0.2; done
UP_PID=""
sleep 0.5
left="$(leftovers)"
[[ -z "$left" ]] && pass "12 stop → no sandbox processes left" || fail "12 leftovers: $left"

if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
echo "RESULT: all checks PASS"
