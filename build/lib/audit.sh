#!/usr/bin/env bash
# audit.sh <root> — verify every Mach-O under <root> is relocatable arm64.
#
# FAIL if:
#   * any load command (LC_LOAD_*DYLIB, LC_ID_DYLIB, LC_RPATH) references a path outside
#     /usr/lib, /System, @rpath, @loader_path, @executable_path
#   * any image has a non-arm64 slice
#   * any image has an invalid code signature
#   * AUDIT_EXPECT_RUNTIME=1 (signed release trees, build/sign.sh): any image without the hardened
#     runtime flag, or — unless ad-hoc signed — without TeamIdentifier=$AUDIT_EXPECT_TEAM (default S25RFUK37U)
# WARN (non-fatal): embedded absolute build-path strings (e.g. OpenSSL's compiled-in OPENSSLDIR).
# Read-only. Exit 0 = clean, 1 = violations.
set -uo pipefail

root="${1:?usage: audit.sh <root> [--no-sign-check]}"
sigcheck=1; [[ "${2:-}" == "--no-sign-check" ]] && sigcheck=0
[[ -e "$root" ]] || { echo "audit: no such path $root" >&2; exit 2; }
expect_runtime="${AUDIT_EXPECT_RUNTIME:-0}"
expect_team="${AUDIT_EXPECT_TEAM:-S25RFUK37U}"

ok_path() {
  case "$1" in
    /usr/lib/*|/System/*|@rpath/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) return 0 ;;
  esac
  return 1
}

files=0; bad=0; viol=0
report() { printf '  ✗ %s: %s\n' "${1#"$root"/}" "$2"; viol=$((viol+1)); }

while IFS= read -r -d '' f; do
  desc="$(file -b "$f" 2>/dev/null)"
  [[ "$desc" == Mach-O* ]] || continue
  [[ "$desc" == *executable* || "$desc" == *"shared library"* || "$desc" == *bundle* ]] || continue
  files=$((files+1)); before=$viol

  archs="$(lipo -archs "$f" 2>/dev/null)"
  [[ "$archs" == "arm64" ]] || report "$f" "arch='$archs' (want arm64 only)"

  # all path-bearing load commands: dylibs (load/weak/reexport/lazy/upward), id, rpath
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ok_path "$p" || report "$f" "$p"
  done < <(otool -l "$f" | awk '
      /cmd LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB|ID_DYLIB|RPATH)$/ {f=1; next}
      f && /^ +(name|path) / {print $2; f=0}')

  if ((sigcheck)) && ! codesign -v "$f" >/dev/null 2>&1; then
    report "$f" "invalid/missing code signature"
  elif [[ "$expect_runtime" == 1 ]]; then
    sig="$(codesign -dv "$f" 2>&1)"
    grep -q 'flags=.*runtime' <<<"$sig" || report "$f" "hardened runtime flag missing"
    if ! grep -q '^Signature=adhoc' <<<"$sig"; then
      team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$sig")"
      [[ "$team" == "$expect_team" ]] || report "$f" "TeamIdentifier='$team' (want $expect_team)"
    fi
  fi
  ((viol > before)) && bad=$((bad+1))
done < <(find "$root" -type f -print0 2>/dev/null)

# informational: embedded absolute build paths (strings), e.g. /opt/homebrew or our stage dir
warn=0
stage_hint="${STAGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.stage}"
while IFS= read -r -d '' f; do
  [[ "$(file -b "$f")" == Mach-O* ]] || continue
  if strings -a "$f" 2>/dev/null | grep -E "^(/opt/homebrew|$stage_hint)" >/dev/null; then
    printf '  ! %s: embeds absolute build path string (runtime override needed?)\n' "${f#"$root"/}"
    warn=$((warn+1))
  fi
done < <(find "$root" -type f -print0 2>/dev/null)

echo "audit: $files Mach-O images, $bad with violations ($viol total), $warn string warnings — $root"
((viol == 0))
