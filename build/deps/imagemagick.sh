#!/usr/bin/env bash
# ImageMagick 7 (Q16 HDRI) → $DEPS_PREFIX, for PECL imagick. Minimal delegates: png, jpeg, webp,
# freetype (+ system zlib/bzip2). No X11/OpenMP/perl/Magick++/modules — coders are built into
# libMagickCore, so no module path is needed at runtime.
#
# Runtime: export MAGICK_CONFIGURE_PATH=<root>/etc/ImageMagick-7 (or MAGICK_HOME=<root>).
# Config XMLs (colors.xml, policy.xml, …) are otherwise looked up at the compiled-in stage path;
# after relocation IM still works (formats, delegates) but warns "UnableToOpenConfigureFile
# colors.xml" whenever a named color is used, and no policy.xml is applied.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$RAMP_BUILD/lib/dep.sh"

dep_start imagemagick "$IMAGEMAGICK_VERSION" "$IMAGEMAGICK_URL" "$IMAGEMAGICK_SHA256"
autotools_build --without-x --disable-openmp --disable-opencl --without-perl --without-magick-plus-plus \
  --disable-docs --with-modules=no \
  --with-png=yes --with-jpeg=yes --with-webp=yes --with-freetype=yes --with-zlib=yes --with-bzlib=yes \
  --without-xml --without-zip --without-zstd --without-lzma --without-tiff --without-heic --without-jxl \
  --without-jbig --without-lcms --without-openjp2 --without-lqr --without-openexr --without-pango \
  --without-raw --without-rsvg --without-wmf --without-djvu --without-fontconfig --without-raqm \
  --without-dmr --without-uhdr --without-fftw --without-flif --without-fpx --without-gslib --without-gvc \
  --without-dps --without-autotrace --without-jemalloc --without-tcmalloc
dep_finish
