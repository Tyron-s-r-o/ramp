#!/usr/bin/env bash
# build-all-ext.sh [php-minor…] — all shared extensions × PHP versions, concurrently, then
# verify each PHP tree from a moved copy and write build/out/ext-matrix.md.
#
#   build/php/build-all-ext.sh                     # 8.1 8.2 8.3 8.4 8.5 7.4 7.3
#   build/php/build-all-ext.sh 8.2                 # one version
#   EXTS="redis xdebug" build/php/build-all-ext.sh # subset of extensions
#   PAR=10 JOBS=2 FORCE=1 build/php/build-all-ext.sh
#
# PAR concurrent jobs (default NPROC*2/3), make -j$JOBS each (default 2). Phalcon (one huge
# amalgamated .c file, several minutes) is queued first. A failing job never stops the others;
# failures are recorded in the matrix. Required: phalcon on 8.2, everything else on every version
# — the script exits 1 if any of those fail (optional: phalcon outside 8.2; n/a on 7.x).
# Per-branch pins (PHP73_PECL_REDIS_*, PHP73_/PHP74_XDEBUG_* …) are honoured like build-ext.sh does.
# Logs: .stage/logs/ext-<ext>-<extver>-php-<ver>.{out,log}.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"

minors=("$@")
((${#minors[@]})) || minors=(8.1 8.2 8.3 8.4 8.5 7.4 7.3)
read -r -a exts <<<"${EXTS:-phalcon imagick memcached redis xdebug yaml apcu}"
export PAR="${PAR:-$(( NPROC * 2 / 3 > 2 ? NPROC * 2 / 3 : 2 ))}"
export JOBS="${JOBS:-2}"
export FORCE="${FORCE:-0}"

vers=()
for m in "${minors[@]}"; do vvar="PHP${m/./}_VERSION"; vers+=("${!vvar:?no $vvar in versions.env}"); done

# pinvar <phpver> <ext> → effective version pin (branch override PHP<MM>_<PIN>_VERSION wins)
pinvar() {
  local v="$1" e="$2" pin mm o g a b
  case "$e" in xdebug) pin=XDEBUG ;; phalcon) pin=PHALCON ;; *) pin="PECL_$(tr a-z A-Z <<<"$e")" ;; esac
  IFS=. read -r a b _ <<<"$v"; mm="$a$b"
  o="PHP${mm}_${pin}_VERSION" g="${pin}_VERSION"
  printf '%s' "${!o:-${!g:-}}"
}
na() { [[ "$2" == phalcon && "$1" == 7.* ]]; }   # Phalcon 5 needs PHP >= 8.1

# ------------------------------------------------------------------ build (job pool)
st="$STAGE_DIR/ext-status"; mkdir -p "$st"; rm -f "$st"/*
t0=$SECONDS
log "building [${exts[*]}] × [${vers[*]}] — $PAR jobs × make -j$JOBS"
for e in "${exts[@]}"; do for v in "${vers[@]}"; do na "$v" "$e" || printf '%s %s\n' "$v" "$e"; done; done \
| xargs -P "$PAR" -n 2 bash -c '
    v="$1" e="$2"
    if "'"$here"'/build-ext.sh" "$v" "$e" >"'"$LOG_DIR"'/ext-$e-php-$v.out" 2>&1; then r=OK; else r=FAIL; fi
    echo "$r" >"'"$st"'/$v-$e"; echo "[ext] $r $e php-$v" >&2' _ || true
log "builds finished in $((SECONDS - t0))s"

# ------------------------------------------------------------------ verify from a moved copy
# results as files (macOS /bin/bash 3.2: no associative arrays)
setr() { printf '%s' "$3" >"$st/$1-$2.res"; printf '%s' "$4" >"$st/$1-$2.why"; }
res() { cat "$st/$1-$2.res" 2>/dev/null || echo "n/a"; }
why() { cat "$st/$1-$2.why" 2>/dev/null || true; }
reason() {  # first compiler/configure/load error of a failed build
  local out="$LOG_DIR/ext-$2-php-$1.out" log
  log="$(ls -t "$LOG_DIR"/ext-"$2"-*-php-"$1".log 2>/dev/null | head -1)"
  { grep -hE 'error:|ERROR:|configure: error|Fatal|Warning: PHP Startup' "${log:-/dev/null}" "$out" 2>/dev/null || true; } \
    | head -1 | sed -E "s|$RAMP_BUILD/?||g; s/\|/\\\\|/g" | cut -c1-160
}
work="$(mktemp -d "${TMPDIR:-/tmp}/ramp-extv.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for v in "${vers[@]}"; do
  cp -R "$OUT_DIR/php/$v" "$work/$v"
  root="$(cd "$work/$v" && pwd -P)"
  rel="$(sed -n 's/.*"extension_dir_rel": "\(.*\)".*/\1/p' "$root/ramp.json")"
  php=("$root/bin/php" -n -d "extension_dir=$root/$rel")
  for e in "${exts[@]}"; do
    if na "$v" "$e"; then setr "$v" "$e" n/a "Phalcon 5 requires PHP >= 8.1"; continue; fi
    if [[ "$(cat "$st/$v-$e" 2>/dev/null)" != OK || ! -f "$root/$rel/$e.so" ]]; then
      setr "$v" "$e" FAIL "build: $(reason "$v" "$e")"; continue
    fi
    case "$e" in
      xdebug)  o="$("${php[@]}" -d zend_extension=xdebug -v 2>&1 || true)"; want="with Xdebug v$(pinvar "$v" xdebug)"
               [[ "$o" == *"$want"* ]] && got="$want" || got="$(head -3 <<<"$o" | tr '\n' ' ')" ;;
      phalcon) o="$("${php[@]}" -d extension=phalcon -r 'echo (new Phalcon\Support\Version)->get();' 2>&1 || true)"; want="$PHALCON_VERSION"; got="$o" ;;
      imagick) o="$("${php[@]}" -d extension=imagick -r 'echo count(Imagick::queryFormats()), " ", Imagick::getVersion()["versionString"];' 2>&1 || true)"
               n="${o%% *}"; [[ "$n" =~ ^[0-9]+$ ]] && ((n > 10)) && want="$o" || want="formats>10"; got="$o" ;;
      *)       o="$("${php[@]}" -d extension="$e" -r "echo phpversion('$e');" 2>&1 || true)"; want="$o"; got="$o"
               [[ -n "$o" && "$o" != *Warning* && "$o" != *rror* ]] || want="(loadable)" ;;
    esac
    if [[ "$got" == "$want" ]]; then setr "$v" "$e" OK "$got"
    else setr "$v" "$e" FAIL "load: $(head -c 160 <<<"$got" | tr '\n|' ' /')"; fi
  done

  # all PECL five together (plan check) + no dylib from outside the moved tree
  load=(); for e in redis apcu yaml imagick memcached; do [[ "$(res "$v" "$e")" == OK ]] && load+=(-d "extension=$e"); done
  [[ "$(res "$v" xdebug)" == OK ]] && load+=(-d zend_extension=xdebug)
  [[ "$(res "$v" phalcon)" == OK ]] && load+=(-d extension=phalcon)
  ((${#load[@]})) && {
    leaks="$(DYLD_PRINT_LIBRARIES=1 "${php[@]}" "${load[@]}" -m 2>&1 >/dev/null \
      | awk '/dyld/ && /\// {print $NF}' | grep -Ev "^($root/|/usr/lib/|/System/)" || true)"
    [[ -z "$leaks" ]] || die "php $v: libraries loaded from outside the tree: $leaks"
  }
  a="$("$RAMP_BUILD/lib/audit.sh" "$OUT_DIR/php/$v" 2>&1)" || { grep '✗' <<<"$a" >&2; die "audit failed for php $v"; }
  log "php $v: $(tail -1 <<<"$a" | sed 's/ — .*//')"
  rm -rf "$root"
done

# ------------------------------------------------------------------ matrix
mx="$OUT_DIR/ext-matrix.md"
{
  echo "# RAMP PHP extension matrix"
  echo
  echo "Generated by \`build/php/build-all-ext.sh\` on $(date '+%Y-%m-%d %H:%M'). Shared \`.so\` files in"
  echo "\`out/php/<ver>/<extension_dir_rel>/\`, **not enabled by default** (the app writes conf.d ini files)."
  echo "Tested from a moved copy of each tree: \`php -n -d extension_dir=<abs> -d extension=<ext>\` (xdebug: \`zend_extension\`)."
  echo
  printf '| extension | pinned |'; for v in "${vers[@]}"; do printf ' %s |' "$v"; done; echo
  printf '|---|---|'; for v in "${vers[@]}"; do printf -- '---|'; done; echo
  for e in "${exts[@]}"; do
    case "$e" in xdebug) p="$XDEBUG_VERSION" ;; phalcon) p="$PHALCON_VERSION" ;; *) pv="PECL_$(tr a-z A-Z <<<"$e")_VERSION"; p="${!pv}" ;; esac
    printf '| %s | %s |' "$e" "$p"
    for v in "${vers[@]}"; do
      r="$(res "$v" "$e")"; bp="$(pinvar "$v" "$e")"
      [[ "$r" == OK && "$bp" != "$p" ]] && r="OK ($bp)"   # branch-specific pin
      printf ' %s |' "$r"
    done; echo
  done
  echo
  echo "## Details"
  echo
  for v in "${vers[@]}"; do for e in "${exts[@]}"; do
    printf -- '- **%s / %s** — %s: %s\n' "$v" "$e" "$(res "$v" "$e")" "$(why "$v" "$e")"
  done; done
} >"$mx"
log "matrix → $mx"
sed -n '/^| extension/,/^$/p' "$mx"

# ------------------------------------------------------------------ required set
bad=()
for v in "${vers[@]}"; do for e in "${exts[@]}"; do
  if [[ "$e" == phalcon && "$v" != 8.2.* ]]; then continue; fi
  [[ "$(res "$v" "$e")" == OK ]] || bad+=("$e@$v")
done; done
((${#bad[@]} == 0)) || die "required extensions failed: ${bad[*]}"
log "all required extensions OK in $((SECONDS - t0))s"
