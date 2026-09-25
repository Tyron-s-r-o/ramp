#!/usr/bin/env bash
# package.sh [component[/version] …] — pack finished out/<component>/<version>/ trees into
#   dist/<component>-<version>-darwin-arm64.tar.xz   (+ .sha256 sidecar, + .json metadata for manifest.sh)
#
#   build/package.sh                     # every finished tree under out/ (php apache mysql redis phpmyadmin elasticvue)
#   build/package.sh php mysql/9.7.2     # subset
#   FORCE=1 build/package.sh             # repack even if the tree fingerprint is unchanged
#   XZ_LEVEL=9 build/package.sh          # default 6 (24 MiB blocks → xz -T0 really uses all cores)
#
# Re-runnable: a tree is repacked only when its fingerprint (path, size, mtime, mode of every packed
# entry) changed, so trees finished later (e.g. PHP 7.3, or extensions added to a PHP tree) are
# picked up by simply re-running. Unfinished trees (no sanity file / no ramp.json for PHP) are skipped.
#
# Archive layout: single top-level dir <component>-<version>/ (the app's PackageInstaller accepts it),
# entries sorted (LC_ALL=C), owner root:wheel, no xattrs / mac metadata / ACLs / flags.
# Compression: stock bsdtar writes the tar stream, `xz -T0` (Homebrew, build-time only) compresses;
# without xz falls back to bsdtar's own liblzma (--options xz:threads=0). Output is plain .tar.xz,
# extractable by stock /usr/bin/tar.
#
# PHP packages additionally get ssl/{cert.pem,openssl.cnf} + etc/ImageMagick-7 from .stage/deps (ISS-003),
# overlaid in a staging clone (.stage/pkgroot) — out/php/<ver> itself is never modified.
#
# Signing (Phase 8, opt-in): SIGN_IDENTITY="Developer ID Application: … (S25RFUK37U)" (or its SHA-1) →
# php/apache/redis are staged into .stage/pkgroot (RAMP_PKGROOT overrides), signed there by build/sign.sh
# (hardened runtime, timestamp, per-binary entitlements) and re-audited with AUDIT_EXPECT_RUNTIME=1 before
# tar. Unset or "-" = previous behaviour (relocate.sh's ad-hoc signatures). The identity is part of the
# fingerprint (changing it repacks); .json metadata gains "signed": "<identity SHA-1>" | "adhoc".
# Use DIST_DIR=<dir> to write signed packages elsewhere. mysql/phpmyadmin/elasticvue are never re-signed.
#
# Audit: php/apache/redis must pass lib/audit.sh (fatal). mysql = Oracle tarball, unmodified: audit is
# warn-only; debug variants (bin/mysqld-debug, lib/plugin/debug/) are dropped from the package.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/common.sh"

COMPONENTS=(php apache mysql redis phpmyadmin elasticvue)
XZ_LEVEL="${XZ_LEVEL:-6}"
FP_DIR="$DIST_DIR/.fp"
mkdir -p "$FP_DIR"

# sanity file per component (same contract as app PackageInstaller.sanityFiles)
sanity_of() {
  case "$1" in
    php) echo sbin/php-fpm ;; apache) echo bin/httpd ;; mysql) echo bin/mysqld ;;
    redis) echo bin/redis-server ;; phpmyadmin) echo index.php ;; elasticvue) echo index.html ;; *) return 1 ;;
  esac
}

# exclude_re COMPONENT VERSION → ERE of relative paths (from out/<component>/) NOT to pack ('' = none)
exclude_re() {
  local v="${2//./\\.}"
  case "$1" in
    mysql) echo "^$v/(bin/mysqld-debug|lib/plugin/debug(/.*)?)\$" ;;
    php)   echo "^$v/lib/php/extensions/[^/]+/[^/]+\\.a\$" ;;   # stray static archives (7.3 opcache.a)
    *) echo '' ;;
  esac
}

# PHP runtime config overlaid into every PHP package (ISS-003) — the app exports
#   SSL_CERT_FILE=<php>/ssl/cert.pem  OPENSSL_CONF=<php>/ssl/openssl.cnf  MAGICK_CONFIGURE_PATH=<php>/etc/ImageMagick-7
# Added in a staging copy (APFS clones), never written into out/php/<ver>.
PHP_EXTRAS=(
  "ssl/cert.pem=$DEPS_PREFIX/ssl/cert.pem"
  "ssl/openssl.cnf=$DEPS_PREFIX/ssl/openssl.cnf"
  "etc/ImageMagick-7=$DEPS_PREFIX/etc/ImageMagick-7"
)
PKGROOT="${RAMP_PKGROOT:-$STAGE_DIR/pkgroot}"

# ---------------------------------------------------------------- signing (opt-in)
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ID_SHA=adhoc
if [[ "$SIGN_IDENTITY" != - ]]; then
  if [[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then SIGN_ID_SHA="$(tr a-f A-F <<<"$SIGN_IDENTITY")"
  else
    ids="$(security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"})"
    SIGN_ID_SHA="$(awk -v id="$SIGN_IDENTITY" 'index($0, "\"" id) {print $2; exit}' <<<"$ids")"
  fi
  [[ -n "$SIGN_ID_SHA" ]] || die "SIGN_IDENTITY '$SIGN_IDENTITY' not found in the keychain (security find-identity -v -p codesigning)"
  log "signing enabled: $SIGN_IDENTITY ($SIGN_ID_SHA)"
fi
# signs COMPONENT → true when this package gets Developer-ID/identity signing (vendor trees never)
signs() { [[ "$SIGN_IDENTITY" != - ]] && case "$1" in php|apache|redis) true ;; *) false ;; esac; }

# parent dir the archive is created from: out/<component> or the staging clone (php overlay / signing)
src_parent() { if [[ "$1" == php ]] || signs "$1"; then echo "$PKGROOT/$1"; else echo "$OUT_DIR/$1"; fi; }

# stage_clone COMPONENT VERSION → $PKGROOT/<comp>/<ver> = APFS clone of out/<comp>/<ver>
stage_clone() {
  local dst="$PKGROOT/$1/$2"
  rm -rf "$dst"; mkdir -p "$PKGROOT/$1"
  cp -c -pR "$OUT_DIR/$1/$2" "$dst" 2>/dev/null || cp -pR "$OUT_DIR/$1/$2" "$dst"
}

# sign_staged COMPONENT VERSION → sign.sh + strict audit on the staging clone (fatal)
sign_staged() {
  local dst="$PKGROOT/$1/$2" lf="$LOG_DIR/package-$1-$2-sign.log"
  SIGN_IDENTITY="$SIGN_IDENTITY" bash "$RAMP_BUILD/sign.sh" "$dst" "$1" >"$lf" 2>&1 \
    || { tail -n 20 "$lf" >&2; die "signing failed for $1 $2 (log: $lf)"; }
  AUDIT_EXPECT_RUNTIME=1 bash "$RAMP_BUILD/lib/audit.sh" "$dst" >>"$lf" 2>&1 \
    || { tail -n 20 "$lf" >&2; die "signed tree audit failed for $1 $2 (log: $lf)"; }
  log "  signed $1 $2 ($(tail -n 1 "$lf"))"
}

# stage_php VERSION → $PKGROOT/php/<ver> = clone of out/php/<ver> + PHP_EXTRAS
stage_php() {
  local ver="$1" dst="$PKGROOT/php/$1" e rel src
  stage_clone php "$ver"
  for e in "${PHP_EXTRAS[@]}"; do
    rel="${e%%=*}" src="${e#*=}"
    [[ -e "$src" ]] || die "php overlay source missing: $src (build deps first)"
    mkdir -p "$(dirname "$dst/$rel")"; rm -rf "${dst:?}/$rel"
    cp -pR "$src" "$dst/$rel"
  done
}

# NUL-separated, sorted entry list relative to PARENT (default out/<component>/)
entry_list() {
  local comp="$1" ver="$2" parent="${3:-$OUT_DIR/$1}" re
  re="$(exclude_re "$comp" "$ver")"
  (cd "$parent" && find "$ver" -print0) \
    | { if [[ -n "$re" ]]; then grep -zEv "$re"; else cat; fi; } \
    | LC_ALL=C sort -z
}

fingerprint() {  # COMPONENT VERSION → sha256 over (path size mtime mode) of every packed source entry
  local comp="$1" ver="$2" e
  { printf 'excl=%s level=%s\n' "$(exclude_re "$comp" "$ver")" "$XZ_LEVEL"
    if signs "$comp"; then printf 'signed=%s\n' "$SIGN_ID_SHA"; fi   # absent when unsigned → old fingerprints stay valid
    (cd "$OUT_DIR/$comp" && entry_list "$comp" "$ver" | xargs -0 stat -f '%N %z %m %p')
    if [[ "$comp" == php ]]; then
      for e in "${PHP_EXTRAS[@]}"; do
        printf 'overlay %s\n' "${e%%=*}"
        find "${e#*=}" -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 stat -f '%N %z %m %p'
      done
    fi; } \
    | shasum -a 256 | awk '{print $1}'
}

# json_meta COMPONENT VERSION FILE SHA SIZE → dist/<pkg>.json
json_meta() {
  local comp="$1" ver="$2" file="$3" sha="$4" size="$5" root="$OUT_DIR/$1/$2"
  local branch; branch="$(awk -F. '{print $1"."$2}' <<<"$ver")"
  local base; base="$(jq -n --arg c "$comp" --arg v "$ver" --arg b "$branch" --arg f "$file" \
      --arg s "$sha" --argjson z "$size" \
      --arg g "$(signs "$comp" && echo "$SIGN_ID_SHA" || echo adhoc)" \
      '{component:$c, version:$v, branch:$b, file:$f, sha256:$s, size:$z, signed:$g}')"
  if [[ "$comp" == php ]]; then
    local rel exts
    rel="$(jq -r .extension_dir_rel "$root/ramp.json")"
    exts="$(find "$root/$rel" -maxdepth 1 -name '*.so' ! -name opcache.so -exec basename {} .so \; 2>/dev/null \
            | LC_ALL=C sort | jq -R . | jq -s .)"
    base="$(jq --argjson r "$(cat "$root/ramp.json")" --argjson e "$exts" \
      '. + {extension_dir_rel:$r.extension_dir_rel, api:$r.api, opcache:$r.opcache, extensions:$e}' <<<"$base")"
  fi
  printf '%s\n' "$base" >"$DIST_DIR/${file%.tar.xz}.json"
}

audit_tree() {  # COMPONENT VERSION → 0 ok (mysql: always 0, findings logged)
  local comp="$1" ver="$2" root="$OUT_DIR/$1/$2" lf="$LOG_DIR/package-$1-$2-audit.log"
  case "$comp" in
    phpmyadmin|elasticvue) return 0 ;;   # no Mach-O
    mysql)
      bash "$RAMP_BUILD/lib/audit.sh" "$root" >"$lf" 2>&1 || true
      local n; n="$(grep -c "✗" "$lf" | tr -d " " || true)"
      local m; m="$(grep '✗' "$lf" | grep -Ev '(bin/mysqld-debug|lib/plugin/debug/)' | grep -c "✗" | tr -d " " || true)"
      [[ "$n" == 0 ]] || log "  mysql $ver audit (warn-only): $n findings, $m in packaged files (Oracle install names) — $lf"
      return 0 ;;
    *)
      if ! bash "$RAMP_BUILD/lib/audit.sh" "$root" >"$lf" 2>&1; then
        tail -n 20 "$lf" >&2; return 1
      fi ;;
  esac
}

pack_one() {
  local comp="$1" ver="$2" root="$OUT_DIR/$1/$2"
  local file="$comp-$ver-darwin-arm64.tar.xz" pkg="$DIST_DIR/$comp-$ver-darwin-arm64.tar.xz"
  local sanity; sanity="$(sanity_of "$comp")"
  if [[ ! -e "$root/$sanity" ]] || [[ "$comp" == php && ! -f "$root/ramp.json" ]]; then
    log "skip $comp $ver — tree not finished ($root/$sanity missing)"; return 0
  fi
  local fp; fp="$(fingerprint "$comp" "$ver")"
  if [[ "${FORCE:-0}" != 1 && -f "$pkg" && -f "$pkg.sha256" && -f "$DIST_DIR/${file%.tar.xz}.json" \
        && "$(cat "$FP_DIR/$file.fp" 2>/dev/null)" == "$fp" ]]; then
    log "up to date: $file"; return 0
  fi
  audit_tree "$comp" "$ver" || die "audit failed for $comp $ver — not packaged"

  local parent; parent="$(src_parent "$comp")"
  if [[ "$comp" == php ]]; then stage_php "$ver"; elif signs "$comp"; then stage_clone "$comp" "$ver"; fi
  if signs "$comp"; then sign_staged "$comp" "$ver"; fi
  local list; list="$(mktemp "$STAGE_DIR/pkglist.XXXXXX")"
  entry_list "$comp" "$ver" "$parent" >"$list"
  local n_in; n_in="$(tr -cd '\0' <"$list" | wc -c | tr -d ' ')"
  local esc="${ver//./\\.}"
  local -a tarflags=(-c -n --null -T "$list" -C "$parent"
                     --uid 0 --gid 0 --uname root --gname wheel
                     --no-xattrs --no-mac-metadata --no-acls --no-fflags
                     -s ",^$esc,$comp-$ver,S")
  local t0=$SECONDS
  log "pack $file ($n_in entries)…"
  rm -f "$pkg.part"
  if command -v xz >/dev/null 2>&1; then
    COPYFILE_DISABLE=1 /usr/bin/tar "${tarflags[@]}" -f - | xz -T0 "-$XZ_LEVEL" -c >"$pkg.part"
  else
    COPYFILE_DISABLE=1 /usr/bin/tar "${tarflags[@]}" -J --options "xz:threads=0,xz:compression-level=$XZ_LEVEL" \
      -f "$pkg.part"
  fi
  rm -f "$list"
  if [[ "$comp" == php ]] || signs "$comp"; then rm -rf "${PKGROOT:?}/$comp/$ver"; fi

  # integrity: stock bsdtar can read it back, entry count matches, tree unchanged while packing
  local n_out; n_out="$(/usr/bin/tar -tf "$pkg.part" | wc -l | tr -d ' ')"
  [[ "$n_out" == "$n_in" ]] || { rm -f "$pkg.part"; die "$file: $n_out entries in archive, expected $n_in"; }
  [[ "$(fingerprint "$comp" "$ver")" == "$fp" ]] || { rm -f "$pkg.part"; die "$root changed while packing — re-run"; }
  mv -f "$pkg.part" "$pkg"

  local sha size
  sha="$(sha256_of "$pkg")"; size="$(stat -f %z "$pkg")"
  (cd "$DIST_DIR" && printf '%s  %s\n' "$sha" "$file" >"$file.sha256")
  json_meta "$comp" "$ver" "$file" "$sha" "$size"
  printf '%s\n' "$fp" >"$FP_DIR/$file.fp"
  log "  → $file $(( size / 1048576 )) MiB, sha256 ${sha:0:16}… ($((SECONDS - t0))s)"
}

targets=()
if (($#)); then
  for a in "$@"; do
    if [[ "$a" == */* ]]; then targets+=("$a")
    else for d in "$OUT_DIR/$a"/*/; do [[ -d "$d" ]] && targets+=("$a/$(basename "$d")"); done; fi
  done
else
  for c in "${COMPONENTS[@]}"; do
    for d in "$OUT_DIR/$c"/*/; do [[ -d "$d" ]] && targets+=("$c/$(basename "$d")"); done
  done
fi
((${#targets[@]})) || die "nothing to package under $OUT_DIR"

for t in "${targets[@]}"; do
  comp="${t%%/*}" ver="${t#*/}"
  sanity_of "$comp" >/dev/null || die "unknown component '$comp'"
  [[ -d "$OUT_DIR/$comp/$ver" ]] || die "no tree $OUT_DIR/$comp/$ver"
  pack_one "$comp" "$ver"
done
log "packages in $DIST_DIR:"
ls -1 "$DIST_DIR"/*.tar.xz 2>/dev/null | sed "s|^$DIST_DIR/|  |" >&2 || true
