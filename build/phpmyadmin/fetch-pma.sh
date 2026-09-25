#!/usr/bin/env bash
# fetch-pma.sh — phpMyAdmin all-languages tarball (sha256-verified) → out/phpmyadmin/<ver>/ (no config yet).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ver="$PHPMYADMIN_VERSION"
out="$OUT_DIR/phpmyadmin/$ver"
if is_built "phpmyadmin-$ver" && [[ -f "$out/index.php" ]]; then
  log "phpmyadmin $ver already present ($out) — FORCE=1 to refetch"
else
  tarball="$(fetch phpmyadmin "$PHPMYADMIN_URL" "$PHPMYADMIN_SHA256")"
  tmp="$(mktemp -d "$WORK_DIR/pma.XXXXXX")"
  top="$(extract "$tarball" "$tmp")"
  rm -rf "$out"; mkdir -p "$(dirname "$out")"
  mv "$top" "$out"
  rm -rf "$tmp"
  mark_built "phpmyadmin-$ver"
fi

# smoke: layout + version constant
[[ -f "$out/index.php" && -f "$out/config.sample.inc.php" && -d "$out/vendor" ]] || die "phpmyadmin: unexpected layout in $out"
grep -rqs "$ver" "$out/libraries/classes/Version.php" || die "phpmyadmin: Version.php does not mention $ver"
log "phpmyadmin $ver OK ($out)"
