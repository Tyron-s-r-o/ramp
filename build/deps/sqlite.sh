#!/usr/bin/env bash
# SQLite → $DEPS_PREFIX. Own build because Apple's omits load_extension; CLI shell without line editing (autosetup --editline check breaks).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start sqlite "$SQLITE_VERSION" "$SQLITE_URL" "$SQLITE_SHA256"
export CFLAGS="$CFLAGS -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 -DSQLITE_SECURE_DELETE=1"
autotools_build --fts3 --fts4 --fts5 --rtree --session --disable-readline --disable-static-shell
dep_finish
