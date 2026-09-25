#!/usr/bin/env bash
# sign.sh <tree-root> <component> — code-sign every self-built Mach-O in a service tree with the
# hardened runtime, inside-out (dylibs → loadable bundles/.so → executables).
#
#   SIGN_IDENTITY="Developer ID Application: … (S25RFUK37U)" build/sign.sh <root> php
#   SIGN_IDENTITY=<SHA-1>  build/sign.sh <root> apache      # identity by hash (CI: setup-keychain.sh)
#   SIGN_IDENTITY=-        build/sign.sh <root> redis       # ad-hoc (default) — runtime flag, no timestamp
#   SIGN_KEYCHAIN=<path>   → passed as --keychain (CI temp keychain)
#   SIGN_JOBS=N            parallel codesign processes (default NPROC; --timestamp is a network call)
#
# Per file: codesign --force --sign "$SIGN_IDENTITY" --options runtime [--timestamp] [--entitlements …]
#   php, php-fpm, php-cgi, phpdbg → entitlements/php.plist (com.apple.security.cs.allow-jit: OPcache JIT
#   + PCRE2 JIT use MAP_JIT on arm64). Everything else: no entitlements (entitlements/default.plist
#   documents that). Never --deep. Library validation stays enabled — every image carries the same Team ID.
#
# Vendor components are NOT touched: mysql (Oracle-signed), elasticsearch (Elastic-signed, never
# repacked), phpmyadmin (no Mach-O). Signing must be the LAST mutation before packing (any
# install_name_tool afterwards invalidates the signature) — package.sh runs it on its staging clone,
# never on build/out.
#
# After signing every file is verified with `codesign --verify --strict`. Exit 0 = all signed + valid.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

root="${1:?usage: sign.sh <tree-root> <component>}"
comp="${2:?usage: sign.sh <tree-root> <component>}"
[[ -d "$root" ]] || { echo "sign: no such directory $root" >&2; exit 2; }
root="$(cd "$root" && pwd)"
identity="${SIGN_IDENTITY:--}"
jobs="${SIGN_JOBS:-$(sysctl -n hw.ncpu)}"
log() { printf '[%s] sign: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

case "$comp" in
  mysql)         log "skip $comp — Oracle-built, keeps Oracle's Developer ID signature"; exit 0 ;;
  elasticsearch) log "skip $comp — Elastic tarball, never repacked, keeps Elastic's signature"; exit 0 ;;
  phpmyadmin)    log "skip $comp — no Mach-O"; exit 0 ;;
  php|apache|redis) ;;
  *) echo "sign: unknown component '$comp'" >&2; exit 2 ;;
esac

# base codesign args shared by every file
base=(--force --sign "$identity" --options runtime)
if [[ "$identity" == - ]]; then base+=(--timestamp=none); else base+=(--timestamp); fi
[[ -n "${SIGN_KEYCHAIN:-}" ]] && base+=(--keychain "$SIGN_KEYCHAIN")
php_ent="$here/entitlements/php.plist"
[[ -f "$php_ent" ]] || { echo "sign: missing $php_ent" >&2; exit 2; }

# classify Mach-O images (regular files only; symlinks point at files signed once)
libs=() bundles=() execs=()
while IFS= read -r -d '' f; do
  desc="$(file -b "$f" 2>/dev/null)"
  [[ "$desc" == Mach-O* ]] || continue
  case "$desc" in
    *"shared library"*) libs+=("$f") ;;
    *bundle*)     bundles+=("$f") ;;
    *executable*) execs+=("$f") ;;
    *) ;;   # object files (.o) etc. — not signable, not loaded
  esac
done < <(find "$root" -type f -print0)
total=$(( ${#libs[@]} + ${#bundles[@]} + ${#execs[@]} ))
((total)) || { log "no Mach-O under $root"; exit 0; }
log "$comp: ${#libs[@]} dylibs, ${#bundles[@]} bundles, ${#execs[@]} executables — identity '$identity'"

# sign_batch ARGS… -- FILES…  (parallel; each worker signs one file)
sign_batch() {
  local -a args=() files=()
  while (($#)); do [[ "$1" == -- ]] && { shift; break; }; args+=("$1"); shift; done
  files=("$@")
  ((${#files[@]})) || return 0
  printf '%s\0' "${files[@]}" \
    | xargs -0 -n 1 -P "$jobs" sh -c 'codesign "$@" 2>&1 | grep -v ": replacing existing signature$" >&2; exit 0' sh "${args[@]}"
}

jit_name() { case "$(basename "$1")" in php|php-fpm|php-cgi|phpdbg) return 0 ;; esac; return 1; }

# 1) dylibs, 2) bundles (.so modules/extensions), 3) executables (JIT entitlement where needed)
sign_batch "${base[@]}" -- "${libs[@]+"${libs[@]}"}"
sign_batch "${base[@]}" -- "${bundles[@]+"${bundles[@]}"}"
plain=() jit=()
for f in "${execs[@]+"${execs[@]}"}"; do
  if [[ "$comp" == php ]] && jit_name "$f"; then jit+=("$f"); else plain+=("$f"); fi
done
sign_batch "${base[@]}" -- "${plain[@]+"${plain[@]}"}"
sign_batch "${base[@]}" --entitlements "$php_ent" -- "${jit[@]+"${jit[@]}"}"

# verify every image (strict) + runtime flag
bad=0
for f in "${libs[@]+"${libs[@]}"}" "${bundles[@]+"${bundles[@]}"}" "${execs[@]+"${execs[@]}"}"; do
  if ! codesign --verify --strict "$f" 2>/dev/null; then
    log "✗ invalid signature: ${f#"$root"/}"; bad=$((bad+1)); continue
  fi
  sig="$(codesign -dv "$f" 2>&1)"   # capture first: grep -q in a pipe would SIGPIPE codesign under pipefail
  grep -q 'flags=.*runtime' <<<"$sig" || { log "✗ no hardened runtime: ${f#"$root"/}"; bad=$((bad+1)); }
done
for f in "${jit[@]+"${jit[@]}"}"; do
  ent="$(codesign -d --entitlements - --xml "$f" 2>/dev/null)"
  grep -q 'com.apple.security.cs.allow-jit' <<<"$ent" \
    || { log "✗ allow-jit entitlement missing: ${f#"$root"/}"; bad=$((bad+1)); }
done
((bad == 0)) || { log "$bad problem(s) in $root"; exit 1; }
log "$comp: $total images signed + verified (${#jit[@]} with allow-jit)"
