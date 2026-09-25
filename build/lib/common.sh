#!/usr/bin/env bash
# Shared build environment + helpers. Source it:  source "$(dirname "$0")/../lib/common.sh"
# Requires bash, set -euo pipefail in the caller.

# ---------------------------------------------------------------- paths
RAMP_BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RAMP_BUILD
export CACHE_DIR="$RAMP_BUILD/.cache/src"
export STAGE_DIR="${RAMP_STAGE_DIR:-$RAMP_BUILD/.stage}"   # override for clean-room test builds
export DEPS_PREFIX="$STAGE_DIR/deps"          # shared C libs (openssl, icu, …)
export WORK_DIR="$STAGE_DIR/work"             # extracted source trees
export LOG_DIR="$STAGE_DIR/logs"
export OUT_DIR="$RAMP_BUILD/out"
export DIST_DIR="${DIST_DIR:-$RAMP_BUILD/dist}"   # override for test/signed packaging runs (never clobber dist/)
mkdir -p "$CACHE_DIR" "$DEPS_PREFIX" "$WORK_DIR" "$LOG_DIR" "$OUT_DIR" "$DIST_DIR"

# shellcheck source=../versions.env
source "$RAMP_BUILD/versions.env"

# ---------------------------------------------------------------- toolchain env
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
export ARCH=arm64
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
export CFLAGS="${CFLAGS:--O2} -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CXXFLAGS="${CXXFLAGS:--O2} -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CPPFLAGS="${CPPFLAGS:-} -I$DEPS_PREFIX/include"
# absolute rpath to the stage lets configure-time test programs run against @rpath deps;
# relocate.sh strips absolute LC_RPATHs afterwards.
export LDFLAGS="${LDFLAGS:-} -arch $ARCH -L$DEPS_PREFIX/lib -Wl,-rpath,$DEPS_PREFIX/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
# macOS ships libz/libbz2 but no .pc files → shims so `Requires.private: zlib` (libpng, curl…) resolve
SYS_PC_DIR="$STAGE_DIR/sys-pkgconfig"
if [[ ! -f "$SYS_PC_DIR/zlib.pc" || ! -f "$SYS_PC_DIR/bzip2.pc" ]]; then
  mkdir -p "$SYS_PC_DIR"
  _zv="$(awk '/#define ZLIB_VERSION/{gsub(/"/,"",$3); print $3}' "$(xcrun --show-sdk-path)/usr/include/zlib.h" 2>/dev/null)"
  printf 'Name: zlib\nDescription: macOS system zlib\nVersion: %s\nLibs: -lz\nCflags:\n' "${_zv:-1.2.12}" >"$SYS_PC_DIR/zlib.pc"
  printf 'Name: bzip2\nDescription: macOS system libbz2\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' >"$SYS_PC_DIR/bzip2.pc"
  unset _zv
fi
# PHP ext/readline finds libedit only via pkg-config (headers: SDK <editline/readline.h>)
[[ -f "$SYS_PC_DIR/libedit.pc" ]] || \
  printf 'Name: libedit\nDescription: macOS system libedit\nVersion: 3.0\nLibs: -ledit\nCflags:\n' >"$SYS_PC_DIR/libedit.pc"
export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig:$SYS_PC_DIR:/usr/lib/pkgconfig"  # never pick up Homebrew .pc files
export NPROC="${NPROC:-$(sysctl -n hw.ncpu)}"

if command -v brew >/dev/null 2>&1; then
  _brew="$(brew --prefix)"
  # build-time tools only (bison>=3, re2c, autotools, cmake); keep them AFTER nothing else links
  export PATH="$_brew/opt/bison/bin:$_brew/opt/re2c/bin:$_brew/bin:$PATH"
  unset _brew
fi

# ---------------------------------------------------------------- logging
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(_ts)" "$*" >&2; exit 1; }

# run_logged STEP cmd…  → output appended to $LOG_DIR/STEP.log (timestamped), tail shown on failure
run_logged() {
  local step="$1"; shift
  local lf="$LOG_DIR/$step.log"
  printf '[%s] $ %s\n' "$(_ts)" "$*" >>"$lf"
  if ! "$@" >>"$lf" 2>&1; then
    printf '[%s] FAILED: %s (log: %s)\n' "$(_ts)" "$*" "$lf" >&2
    tail -n 40 "$lf" >&2
    return 1
  fi
}

# ---------------------------------------------------------------- download
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# fetch NAME URL SHA256  → prints cached file path; fails hard on checksum mismatch
fetch() {
  local name="$1" url="$2" sha="$3"
  [[ -n "$sha" ]] || die "fetch $name: empty sha256 (refusing unverified download)"
  local base="${url##*/}"
  # tag archives (…/refs/tags/1.1.4.tar.gz) → prefix with NAME to avoid collisions
  [[ "$base" =~ ^v?[0-9] ]] && base="$name-${base#v}"
  local file="$CACHE_DIR/$base"
  if [[ -f "$file" && "$(sha256_of "$file")" == "$sha" ]]; then
    printf '%s\n' "$file"; return 0
  fi
  log "fetch $name ← $url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$file.part" "$url" || die "download failed: $url"
  local got; got="$(sha256_of "$file.part")"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$file.part"
    die "sha256 mismatch for $name: expected $sha, got $got"
  fi
  mv "$file.part" "$file"
  printf '%s\n' "$file"
}

# extract ARCHIVE [DESTPARENT] → prints top-level source dir (fresh copy every time)
extract() {
  local archive="$1" dest="${2:-$WORK_DIR}"
  local top
  # awk drains the listing (head would SIGPIPE tar → pipefail false-negative on big archives)
  top="$(tar -tf "$archive" | awk -F/ 'NR==1{print $1}')"
  [[ -n "$top" ]] || die "cannot read archive $archive"
  rm -rf "${dest:?}/$top"
  mkdir -p "$dest"
  tar -xf "$archive" -C "$dest"
  printf '%s\n' "$dest/$top"
}

# done_marker NAME → true if already built (skip unless FORCE=1)
is_built() { [[ "${FORCE:-0}" != 1 && -f "$STAGE_DIR/.built/$1" ]]; }
mark_built() { mkdir -p "$STAGE_DIR/.built"; date >"$STAGE_DIR/.built/$1"; }
