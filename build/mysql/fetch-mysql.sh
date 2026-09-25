#!/usr/bin/env bash
# fetch-mysql.sh [9.7|8.4 …] — official MySQL macOS arm64 tarballs (sha256-verified) → out/mysql/<ver>/.
# No source build: Oracle's tarball is relocatable via --basedir (bin → @loader_path/../lib).
# We do NOT relocate/re-sign (keeps Oracle's signatures); audit.sh runs and its findings are logged.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

series=("$@"); ((${#series[@]})) || series=(9.7 8.4)

for s in "${series[@]}"; do
  key="MYSQL${s//./}"
  ver_var="${key}_VERSION" url_var="${key}_URL" sha_var="${key}_SHA256"
  ver="${!ver_var:?no $ver_var in versions.env}"
  out="$OUT_DIR/mysql/$ver"
  if is_built "mysql-$ver" && [[ -x "$out/bin/mysqld" ]]; then
    log "mysql $ver already present ($out) — FORCE=1 to refetch"; continue
  fi
  tarball="$(fetch "mysql$s" "${!url_var}" "${!sha_var}")"
  tmp="$(mktemp -d "$WORK_DIR/mysql.XXXXXX")"
  top="$(extract "$tarball" "$tmp")"
  rm -rf "$out"; mkdir -p "$(dirname "$out")"
  mv "$top" "$out"; rm -rf "$tmp"
  "$out/bin/mysqld" --version
  log "mysql $ver audit (informational — tarball shipped unmodified):"
  bash "$RAMP_BUILD/lib/audit.sh" "$out" | tee "$LOG_DIR/mysql-$ver-audit.log" | tail -n 20 || true
  mark_built "mysql-$ver"
done
