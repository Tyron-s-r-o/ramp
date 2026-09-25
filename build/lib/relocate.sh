#!/usr/bin/env bash
# relocate.sh <root> — make every Mach-O under <root> location-independent.
#
#  * dylib ids            → @rpath/<basename>
#  * non-system deps      → @rpath/<basename>  (copied into <root>/lib if missing)
#  * LC_RPATH             → @loader_path-relative path to <root>/lib; absolute rpaths removed
#  * ad-hoc re-sign       → every touched Mach-O (install_name_tool invalidates signatures,
#                           unsigned arm64 code is SIGKILLed by the kernel)
#
# System deps (/usr/lib, /System) are left alone. Idempotent.
set -euo pipefail

root="${1:?usage: relocate.sh <root>}"
[[ -d "$root" ]] || { echo "relocate: no such dir $root" >&2; exit 1; }
root="$(cd "$root" && pwd -P)"
libdir="$root/lib"

is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Mach-O images we care about (not .o objects, not static archives)
is_macho_image() {
  local d; d="$(file -b "$1" 2>/dev/null)" || return 1
  [[ "$d" == Mach-O* ]] && [[ "$d" == *executable* || "$d" == *"shared library"* || "$d" == *bundle* ]]
}
is_dylib() { [[ "$(file -b "$1")" == *"shared library"* ]]; }

# relative path from directory $1 to directory $2 (both absolute, physical)
relpath() {
  local from="$1" to="$2" common="$1" up=""
  while [[ "$to" != "$common" && "$to" != "$common"/* ]]; do
    common="$(dirname "$common")"; up="../$up"
  done
  local rest="${to#"$common"}"; rest="${rest#/}"
  local r="${up}${rest}"; r="${r%/}"
  printf '%s' "${r:-.}"
}

deps_of()   { otool -L "$1" | tail -n +2 | awk '{print $1}'; }
own_id()    { otool -D "$1" | tail -n +2 | head -1; }
rpaths_of() { otool -l "$1" | awk '/cmd LC_RPATH/{f=1;next} f&&/ path /{print $2; f=0}'; }

changed=()
process() {
  local f="$1" args=() id dep base rp want relsig=0
  local dir; dir="$(cd "$(dirname "$f")" && pwd -P)"

  if is_dylib "$f"; then
    id="$(own_id "$f")"
    base="$(basename "$f")"
    # keep versioned SONAME basename if id already names one (e.g. libssl.3.dylib)
    [[ -n "$id" ]] && base="$(basename "$id")"
    [[ "$id" == "@rpath/$base" ]] || args+=(-id "@rpath/$base")
  fi

  local needs_rpath=0
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ -n "${id:-}" && "$dep" == "$id" ]] && continue
    is_system "$dep" && continue
    case "$dep" in
      @rpath/*) needs_rpath=1; continue ;;
      @loader_path/*|@executable_path/*) continue ;;
    esac
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        echo "relocate: $f links Homebrew/local lib $dep — refusing (fix the build's search paths)" >&2
        exit 1 ;;
    esac
    base="$(basename "$dep")"
    if [[ ! -e "$libdir/$base" ]]; then
      [[ -e "$dep" ]] || { echo "relocate: $f needs $dep which does not exist" >&2; exit 1; }
      mkdir -p "$libdir"
      cp -L "$dep" "$libdir/$base"; chmod u+w "$libdir/$base"
      echo "relocate: bundled $dep → lib/$base" >&2
      queue+=("$libdir/$base")
    fi
    args+=(-change "$dep" "@rpath/$base")
    needs_rpath=1
  done < <(deps_of "$f")

  # rpath: remove absolute ones, add loader-relative path to lib/
  while IFS= read -r rp; do
    [[ -z "$rp" ]] && continue
    [[ "$rp" == @* ]] || args+=(-delete_rpath "$rp")
  done < <(rpaths_of "$f")
  if ((needs_rpath)); then
    local rel; rel="$(relpath "$dir" "$libdir")"
    if [[ "$rel" == "." ]]; then want="@loader_path"; else want="@loader_path/$rel"; fi
    rpaths_of "$f" | grep -xF "$want" >/dev/null || args+=(-add_rpath "$want")
  fi

  if ((${#args[@]})); then
    chmod u+w "$f"
    local out
    out="$(install_name_tool "${args[@]}" "$f" 2>&1)" || { echo "relocate: install_name_tool failed on $f: $out" >&2; exit 1; }
    [[ -n "$out" ]] && grep -v 'will invalidate the code signature' <<<"$out" >&2 || true
    relsig=1
  fi
  # always make sure signature is valid (copied/touched files, or linker-signed already fine)
  if ((relsig)) || ! codesign -v "$f" >/dev/null 2>&1; then
    codesign -f -s - "$f" >/dev/null 2>&1 || { echo "relocate: codesign failed for $f" >&2; exit 1; }
    changed+=("$f")
  fi
}

queue=()
while IFS= read -r -d '' f; do
  is_macho_image "$f" && queue+=("$f")
done < <(find "$root" -type f -print0)

seen=" "
i=0
while ((i < ${#queue[@]})); do
  f="${queue[$i]}"; i=$((i+1))
  [[ "$seen" == *" $f "* ]] && continue
  seen+="$f "
  process "$f"
done

echo "relocate: $i Mach-O scanned, ${#changed[@]} rewritten+signed under $root"
