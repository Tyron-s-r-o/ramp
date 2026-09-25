#!/usr/bin/env bash
# Helpers for build/deps/*.sh — source AFTER common.sh.
#
#   dep_start NAME VERSION URL SHA256   → sets $DEP ("NAME-VERSION") and $SRC, cd's into $SRC;
#                                         exits the script with 0 if already built (FORCE=1 rebuilds)
#   autotools_build [configure args…]   → ./configure --prefix=$DEPS_PREFIX --disable-static … && make && install
#   cmake_build [cmake args…]           → cmake (Ninja, Homebrew prefixes ignored) && build && install
#   dep_finish                          → relocate + audit $DEPS_PREFIX, mark built
#
# RAMP_DEFER_RELOCATE=1 (set by deps/all.sh when building a level concurrently) skips the
# relocate/audit in dep_finish — all.sh runs them once per level so parallel installs
# never race with install_name_tool/codesign.

dep_start() {
  local name="$1" ver="$2" url="$3" sha="$4"
  DEP="$name-$ver"
  if is_built "$DEP"; then log "$DEP already built (FORCE=1 to rebuild)"; exit 0; fi
  local tb; tb="$(fetch "$name" "$url" "$sha")"
  SRC="$(extract "$tb")"
  : >"$LOG_DIR/$DEP.log"
  log "build $DEP (-j$NPROC, log: $LOG_DIR/$DEP.log)"
  cd "$SRC"
}

autotools_build() {
  run_logged "$DEP" ./configure --prefix="$DEPS_PREFIX" --libdir="$DEPS_PREFIX/lib" \
    --enable-shared --disable-static "$@"
  run_logged "$DEP" make -j"$NPROC"
  run_logged "$DEP" make install
}

cmake_build() {
  run_logged "$DEP" cmake -S "$SRC" -B "$SRC/_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_INSTALL_RPATH=@loader_path/../lib \
    -DBUILD_SHARED_LIBS=ON \
    "$@"
  run_logged "$DEP" cmake --build "$SRC/_build" -j "$NPROC"
  run_logged "$DEP" cmake --install "$SRC/_build"
}

# relocate + audit the whole deps prefix (prints audit summary line only; full report on failure)
deps_relocate_audit() {
  run_logged relocate "$RAMP_BUILD/lib/relocate.sh" "$DEPS_PREFIX"
  local out
  if ! out="$("$RAMP_BUILD/lib/audit.sh" "$DEPS_PREFIX" 2>&1)"; then
    printf '%s\n' "$out" | grep '✗' | head -40 >&2
    printf '%s\n' "$out" | tail -1 >&2
    die "audit failed for $DEPS_PREFIX"
  fi
  log "$(printf '%s\n' "$out" | tail -1)"
}

dep_finish() {
  [[ "${RAMP_DEFER_RELOCATE:-0}" == 1 ]] || deps_relocate_audit
  mark_built "$DEP"
  log "$DEP done"
}
