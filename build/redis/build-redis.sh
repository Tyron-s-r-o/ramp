#!/usr/bin/env bash
# build-redis.sh — Redis core only (`make build redis`: no Rust/CMake modules), no TLS.
# Output: out/redis/<ver>/bin/{redis-server,redis-cli,redis-benchmark,…}
# Smoke (from a moved copy): redis-server --port 16379 → redis-cli ping → PONG.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

name=redis
ver="$REDIS_VERSION"
out="$OUT_DIR/redis/$ver"

if is_built "redis-$ver" && [[ -x "$out/bin/redis-server" ]]; then
  log "redis $ver already built ($out) — FORCE=1 to rebuild"
else
  src_tgz="$(fetch "$name" "$REDIS_URL" "$REDIS_SHA256")"
  src="$(extract "$src_tgz")"
  cd "$src"
  # Redis links nothing from deps; the -Wl,… build LDFLAGS break its raw `ld` module_tests link
  export LDFLAGS="-arch $ARCH" CPPFLAGS=""
  # core only; libc malloc is the macOS default; TLS off (local dev cache)
  run_logged redis-build make -j"$NPROC" build redis BUILD_TLS=no USE_SYSTEMD=no
  rm -rf "$out"
  run_logged redis-install make -C src install PREFIX="$out" BUILD_TLS=no
  install -m 644 redis.conf "$out/redis.conf.default"
  bash "$RAMP_BUILD/lib/relocate.sh" "$out"
  bash "$RAMP_BUILD/lib/audit.sh" "$out"
  otool -L "$out/bin/redis-server" | grep -E '/opt/homebrew|/usr/local' && die "redis links Homebrew libs"
  mark_built "redis-$ver"
fi

# ---------------------------------------------------------------- smoke from moved copy
[[ "${SKIP_SMOKE:-0}" == 1 ]] && exit 0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ramp-redis-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp -R "$out" "$tmp/moved"
port="${SMOKE_PORT:-16379}"
"$tmp/moved/bin/redis-server" --port "$port" --bind 127.0.0.1 --daemonize no \
  --save '' --appendonly no --dir "$tmp" >"$tmp/redis.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  "$tmp/moved/bin/redis-cli" -p "$port" ping >/dev/null 2>&1 && break
  sleep 0.1
done
reply="$("$tmp/moved/bin/redis-cli" -p "$port" ping || true)"
"$tmp/moved/bin/redis-server" --version
"$tmp/moved/bin/redis-cli" -p "$port" shutdown nosave >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
[[ "$reply" == PONG ]] || { cat "$tmp/redis.log" >&2; die "redis smoke: expected PONG, got '$reply'"; }
log "redis smoke OK: PONG from moved copy (port $port)"
