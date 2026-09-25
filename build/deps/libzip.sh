#!/usr/bin/env bash
# libzip (cmake) → $DEPS_PREFIX. zlib/bzip2 from macOS, crypto via CommonCrypto; no lzma/zstd.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start libzip "$LIBZIP_VERSION" "$LIBZIP_URL" "$LIBZIP_SHA256"
cmake_build -DENABLE_COMMONCRYPTO=ON -DENABLE_OPENSSL=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF \
  -DENABLE_BZIP2=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
  -DBUILD_TOOLS=ON -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
dep_finish
