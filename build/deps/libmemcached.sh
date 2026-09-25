#!/usr/bin/env bash
# libmemcached-awesome (cmake) → $DEPS_PREFIX (PECL memcached). No SASL/dtrace/tests/docs.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libmemcached "$LIBMEMCACHED_VERSION" "$LIBMEMCACHED_URL" "$LIBMEMCACHED_SHA256"
cmake_build -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DBUILD_DOCS_MAN=OFF -DBUILD_DOCS_HTML=OFF \
  -DENABLE_SASL=OFF -DENABLE_DTRACE=OFF -DENABLE_OPENSSL_CRYPTO=OFF \
  -DENABLE_HASH_HSIEH=ON -DENABLE_HASH_FNV64=ON -DENABLE_HASH_MURMUR=ON -DENABLE_MEMASLAP=OFF
dep_finish
