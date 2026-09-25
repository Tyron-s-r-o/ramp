# RAMP build pipeline

Builds relocatable macOS arm64 binaries (PHP, Apache, Redis, shared C libs). Output runs from any
directory, links only `/usr/lib` + `/System` + `@rpath`/`@loader_path`, never Homebrew.

## Quick start

```bash
build/bootstrap-toolchain.sh      # Homebrew build-time tools (idempotent)
build/deps/all.sh                 # all shared C deps (OpenSSL, ICU, libxml2, curl, ImageMagick…) → build/.stage/deps
build/php/build-all-8x.sh         # PHP 8.1–8.5 (FPM+CLI) concurrently → build/out/php/<ver>, + FPM smoke test
build/php/build-all-ext.sh        # redis apcu yaml imagick memcached xdebug phalcon × 8.1–8.5 → out/ext-matrix.md
build/package.sh && build/manifest.sh   # dist/*.tar.xz + dist/manifest.json  (or: build/build-all.sh)
```

Every script is idempotent (skips finished steps); `FORCE=1` rebuilds.

## Layout

| Path | Purpose |
|---|---|
| `versions.env` | every pinned version + URL + SHA256 (single source of truth) |
| `lib/common.sh` | env (arm64, `MACOSX_DEPLOYMENT_TARGET=27.0`, headerpad LDFLAGS, `NPROC`), `fetch`, `extract`, `run_logged`, `is_built`/`mark_built` |
| `lib/relocate.sh <root>` | rewrite Mach-O ids/deps to `@rpath`, bundle missing non-system dylibs into `<root>/lib`, set `@loader_path`-relative LC_RPATH, ad-hoc re-sign |
| `lib/audit.sh <root>` | fail on non-relocatable load paths, non-arm64 slices, invalid signatures; warn on embedded build-path strings |
| `lib/dep.sh` | dep-script helpers: `dep_start`, `autotools_build`, `cmake_build` (Homebrew prefixes ignored), `dep_finish` |
| `deps/*.sh`, `deps/all.sh` | shared C libraries → `.stage/deps`; `all.sh` builds each dependency level concurrently (`ONLY="…"` subset, `RAMP_STAGE_DIR=…` clean-room) |
| `php/build-php.sh <ver>` | one PHP 8.x → `out/php/<ver>` (+ `ramp.json`: api, `extension_dir_rel`, opcache shared/static); `verify-php.sh` self-test, `smoke-fpm.sh <ver> [root]` FastCGI request; runtime needs `-c php.ini` with absolute `extension_dir` |
| `.cache/src/` | verified source tarballs (gitignored) |
| `.stage/deps/` | shared C libs prefix; `.stage/<component>/<version>/` staging; `.stage/logs/*.log` |
| `out/<component>/<version>/` | final relocatable tree |
| `package.sh [comp[/ver]…]` | `out/<comp>/<ver>` → `dist/<comp>-<ver>-darwin-arm64.tar.xz` (+ `.sha256`, `.json` meta); re-runnable (repacks only changed trees); PHP gets `ssl/{cert.pem,openssl.cnf}` + `etc/ImageMagick-7` overlaid; MySQL without debug binaries |
| `manifest.sh` | `dist/manifest.json` (schema 1, URLs `${RAMP_DIST_BASE}/<file>`, Elasticsearch → official elastic.co tarball + sha512) |
| `sign.sh <root> <component>` | Developer ID / hardened-runtime signing of a service tree (inside-out, per-binary entitlements); called by `package.sh` when `SIGN_IDENTITY` is set |
| `entitlements/*.plist` | `php.plist` (`allow-jit`) for php/php-fpm/php-cgi/phpdbg; `default.plist` = none (documentation) |
| `notarize.sh [--submit] … <pkg.tar.xz>…` | zip signed Mach-O for `notarytool`, verify Developer ID + runtime + timestamp; dry-run by default |
| `build-all.sh [step…]` | whole pipeline: toolchain deps php8 php73 ext apache redis mysql pma elasticvue package manifest (`FROM=<step>`) |
| `elasticvue/fetch-elasticvue.sh` | Elasticvue web GUI: pinned GitHub tag archive (sha256) built with npm (`VITE_APP_BUILD_MODE=docker`, public path `/elasticvue/`, default clusters from `<base>/api/default_clusters.json`, update check off) → `out/elasticvue/<ver>`; needs node ≥ 24 at build time only |
| `dist/<component>-<version>-darwin-arm64.tar.xz` | packages (xz, extractable by stock `/usr/bin/tar`; app rejects zstd) |

## Conventions

- Downloads: `fetch NAME URL SHA256` — hard fail on mismatch, no unverified downloads.
- Linking: `-Wl,-headerpad_max_install_names` always. During build `LDFLAGS` carries an absolute
  `-rpath` to `.stage/deps/lib` so configure-time test programs run; `relocate.sh` strips it.
- After relocation: dylib ids `@rpath/libX.dylib`; rpath `@loader_path/../lib` (bin/sbin),
  `@loader_path` (lib/), computed relative path for deeper dirs (e.g. `lib/ossl-modules` → `@loader_path/..`).
- `relocate.sh` refuses deps under `/opt/homebrew` or `/usr/local`.
- Every modified Mach-O is ad-hoc signed (`codesign -f -s -`); unsigned arm64 code is killed.

## Runtime environment (set by the app)

OpenSSL paths (`OPENSSLDIR`, `MODULESDIR`, `ENGINESDIR`) are compiled-in stage paths and do not exist
on user machines. The app must export for every service using OpenSSL:

```
SSL_CERT_FILE=<deps>/ssl/cert.pem          # Mozilla CA bundle (curl.se, pinned in versions.env)
OPENSSL_CONF=<deps>/ssl/openssl.cnf
OPENSSL_MODULES=<deps>/lib/ossl-modules    # only if the legacy provider is needed
```

ImageMagick (for imagick): `MAGICK_CONFIGURE_PATH=<deps>/etc/ImageMagick-7` (else named colors warn, no policy.xml).
macOS has no `zlib.pc`/`bzip2.pc` — `common.sh` generates shims in `.stage/sys-pkgconfig` (build-time only).

## Signing & notarization (Phase 8)

Default builds stay ad-hoc signed (relocate.sh). For release packages:

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (S25RFUK37U)" DIST_DIR=/tmp/ramp-signed build/package.sh php apache redis
build/notarize.sh --submit --profile ramp-notary /tmp/ramp-signed/{php,apache,redis}-*.tar.xz   # without --submit: dry-run
```

- `SIGN_IDENTITY` — name or SHA-1 (`security find-identity -v -p codesigning`); unset/`-` = unchanged ad-hoc pipeline.
  `SIGN_KEYCHAIN` = CI temp keychain. `DIST_DIR` / `RAMP_PKGROOT` redirect output / staging (never clobber `dist/`).
- Signing is the **last** mutation: `package.sh` clones `out/<c>/<v>` into `.stage/pkgroot`, runs `sign.sh` there,
  then `AUDIT_EXPECT_RUNTIME=1 lib/audit.sh` (runtime flag + TeamIdentifier `S25RFUK37U`, override `AUDIT_EXPECT_TEAM`).
  `build/out` is never modified. The identity is part of the package fingerprint (switching identity repacks);
  `<pkg>.json` records `"signed": "<SHA-1>" | "adhoc"` and, after notarization, `"notarized": "<submission id>"`.
- Order: dylibs → bundles (`.so`, Apache modules) → executables; `--options runtime`, `--timestamp`; never `--deep`.
- Entitlements: only `php`, `php-fpm`, `php-cgi`, `phpdbg` get `com.apple.security.cs.allow-jit` (OPcache JIT and
  PCRE2 JIT use `MAP_JIT` on arm64). Library validation stays on — every image has the same Team ID, so extensions
  and Apache modules load. Consequence: a signed `httpd`/`php` **refuses ad-hoc or foreign-team modules**
  (e.g. user-compiled extensions) — "mapping process and mapped file (non-platform) have different Team IDs".
- Vendor binaries are never re-signed: MySQL (Oracle Developer ID), Elasticsearch (Elastic, not repacked),
  phpMyAdmin and Elasticvue (no Mach-O).
- Notarization: `notarytool` does not take `.tar.xz` → `notarize.sh` zips the Mach-O (paths preserved) only for
  submission; tickets for stand-alone binaries cannot be stapled, Gatekeeper checks online. Credentials:
  `--profile` (keychain profile from `notarytool store-credentials`) or `--api-key/--key-id/--issuer`
  (env `NOTARY_KEY_P8[_BASE64]`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`); a temp `.p8` is 0600 and deleted on exit.
- Smoke a signed tree: `APACHE_ROOT=<x>/apache-… PHP_ROOT=<x>/php-8.3.… PHP_VER=8.3.… build/apache/smoke-apache.sh`.

## CI / releases (Phase 8)

`.github/workflows/binaries.yml` runs the same pipeline on a macOS 27 arm64 runner, signs + notarizes (secrets),
and `build/ci/assemble-release.sh build/dist release/` validates + collects the payload (packages, `.sha256`,
`manifest.json`, `packages.json`, `release-notes.md`). Secrets, runner, repo layout: `build/ci/README.md`.
