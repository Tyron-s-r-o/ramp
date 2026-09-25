#!/usr/bin/env bash
# assemble-release.sh <dist-dir> <out-dir> — collect + validate the binaries release payload.
#
#   build/ci/assemble-release.sh build/dist release/          # CI (binaries.yml) and locally, identical
#   RAMP_RELEASE_TAG=binaries-2026.10.01-test build/ci/assemble-release.sh build/dist /tmp/rel
#   RAMPCTL=<path to rampctl> …   additionally decode the assembled manifest with the app's RAMPCore
#                                 (`rampctl manifest validate --verify-files`)
#
# Copies into <out-dir>: every package named by manifest.json (*.tar.xz + .sha256), manifest.json,
# packages.json (the per-package .json metadata merged, incl. "signed"/"notarized"), release-notes.md.
# Validation mirrors RAMPCore Manifest.decode + PackageInstaller: schema 1; each entry has version/url/hash;
# self-built entries use the literal ${RAMP_DIST_BASE}/<file> URL (resolved by the app against the manifest's
# own URL → manifest + packages must be assets of the same release), file present, sha256 + size recomputed;
# Elasticsearch points to artifacts.elastic.co with sha512 (not redistributed). Packages in <dist-dir> that
# the manifest does not reference (older versions of a branch) are NOT released (warning).
# THIRD_PARTY_LICENSES.md must be current (third-party-licenses.sh --check).
#
# Prints the release tag on stdout (last line): $RAMP_RELEASE_TAG or binaries-<YYYY.MM.DD>-<git short sha>;
# also written to <out-dir>/release-tag.txt and, in GitHub Actions, to $GITHUB_OUTPUT (tag=…).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$(cd "$here/.." && pwd)"
repo_root="$(cd "$build/.." && pwd)"

die() { printf 'assemble-release: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'assemble-release: %s\n' "$*" >&2; }

dist="${1:?usage: assemble-release.sh <dist-dir> <out-dir>}"
out="${2:?usage: assemble-release.sh <dist-dir> <out-dir>}"
[[ -d "$dist" ]] || die "no dist dir $dist"
dist="$(cd "$dist" && pwd)"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
[[ "$out" != "$dist" ]] || die "out-dir must differ from dist-dir"
[[ -z "$(ls -A "$out")" ]] || die "out-dir $out is not empty"
m="$dist/manifest.json"
[[ -f "$m" ]] || die "no $m — run build/manifest.sh"

# shellcheck source=../versions.env
source "$build/versions.env"
placeholder='${RAMP_DIST_BASE}'
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- manifest validation
jq -e 'type == "object"' "$m" >/dev/null || die "manifest.json is not a JSON object"
[[ "$(jq -r '.schema' "$m")" == 1 ]] || die "manifest schema $(jq -r .schema "$m") ≠ 1"
jq -e '.components | type == "object"' "$m" >/dev/null || die "manifest has no components object"

errors=0 files=()
fail() { printf '  ✗ %s\n' "$*" >&2; errors=$((errors+1)); }
while IFS=$'\x1f' read -r comp branch version url sha256 sha512 size file; do   # US separator: tabs would collapse empty fields
  id="$comp $branch"
  [[ -n "$version" ]] || fail "$id: version missing"
  [[ "$size" =~ ^[0-9]+$ || "$size" == null ]] || fail "$id: size '$size' not a number"
  if [[ "$comp" == elasticsearch ]]; then
    [[ "$url" == https://artifacts.elastic.co/* ]] || fail "$id: url must be the official elastic.co artifact ($url)"
    [[ "$sha512" =~ ^[0-9a-f]{128}$ ]] || fail "$id: sha512 missing/invalid"
    [[ "$sha512" == "$ES_SHA512" ]] || fail "$id: sha512 differs from versions.env ES_SHA512"
    continue
  fi
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { fail "$id: sha256 missing/invalid"; continue; }
  [[ "$url" == "$placeholder/$file" ]] || fail "$id: url '$url' ≠ '$placeholder/$file' (placeholder must stay literal)"
  [[ "$file" == "$comp-$version-darwin-arm64.tar.xz" ]] || fail "$id: file '$file' does not match $comp-$version"
  p="$dist/$file"
  [[ -f "$p" ]] || { fail "$id: $file missing in $dist"; continue; }
  [[ "$(sha256 "$p")" == "$sha256" ]] || fail "$id: sha256 of $file does not match the manifest"
  [[ "$size" == null || "$(stat -f %z "$p")" == "$size" ]] || fail "$id: size of $file ≠ $size"
  [[ -f "$p.sha256" ]] && ! grep -q "^$sha256  $file\$" "$p.sha256" && fail "$id: $file.sha256 sidecar is stale"
  /usr/bin/tar -tf "$p" 2>/dev/null | awk -F/ 'NR==1{print $1}' | grep -x -q "$comp-$version" \
    || fail "$id: archive top-level dir is not $comp-$version/"
  files+=("$file")
done < <(jq -r '.components | to_entries[] | .key as $c | .value | to_entries[]
          | [$c, .key, .value.version // "", .value.url // "", .value.sha256 // "", .value.sha512 // "",
             (.value.size // null | tostring), .value.file // ""] | join("\u001f")' "$m")
((${#files[@]})) || fail "manifest references no packages"
((errors == 0)) || die "$errors manifest problem(s)"
log "manifest OK: ${#files[@]} packages + elasticsearch"

# unreferenced packages (older versions sharing a branch) are not released
for p in "$dist"/*-darwin-arm64.tar.xz; do
  f="$(basename "$p")"
  printf '%s\n' "${files[@]}" | grep -qx "$f" || log "WARN $f is not in manifest.json — not released"
done

# ---------------------------------------------------------------- licenses current?
"$build/third-party-licenses.sh" --check >&2 || die "THIRD_PARTY_LICENSES.md is stale — run build/third-party-licenses.sh"

# ---------------------------------------------------------------- copy payload
for f in "${files[@]}"; do
  cp -p "$dist/$f" "$out/$f"
  if [[ -f "$dist/$f.sha256" ]]; then cp -p "$dist/$f.sha256" "$out/$f.sha256"
  else (cd "$out" && printf '%s  %s\n' "$(sha256 "$f")" "$f" >"$f.sha256"); fi
done
cp -p "$m" "$out/manifest.json"
metas=()
for f in "${files[@]}"; do
  j="$dist/${f%.tar.xz}.json"
  [[ -f "$j" ]] && metas+=("$j") || log "WARN no metadata $(basename "$j")"
done
jq -s 'sort_by(.component, .version)' "${metas[@]}" >"$out/packages.json"

# ---------------------------------------------------------------- release tag + notes
if [[ -n "${RAMP_RELEASE_TAG:-}" ]]; then tag="$RAMP_RELEASE_TAG"
else
  sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  tag="binaries-$(date -u '+%Y.%m.%d')-$sha"
fi
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release tag '$tag'"

unsigned="$(jq -r '[.[] | select((.signed // "adhoc") == "adhoc" and (.component | IN("php","apache","redis")))
                    | .file] | join(", ")' "$out/packages.json")"
{
  echo "# RAMP binaries $tag"
  echo
  echo "macOS 27+ · Apple silicon (arm64). Installed and updated by the RAMP app from"
  echo "\`https://github.com/$RAMP_BINARIES_REPO/releases/latest/download/manifest.json\`."
  echo
  echo "| Component | Branch | Version | Size | SHA-256 | Signed | Notarized |"
  echo "|---|---|---|---|---|---|---|"
  jq -r --slurpfile p "$out/packages.json" '.components | to_entries[] | .key as $c | .value | to_entries[]
     | .value as $e | ($p[0] | map(select(.file == $e.file)) | first // {}) as $meta
     | "| \($c) | \(.key) | \($e.version) | "
       + (if $e.size then "\(($e.size / 1048576 * 10 | floor) / 10) MiB" else "–" end) + " | "
       + (if $e.sha256 then "`\($e.sha256[0:16])…`" else "sha512 (elastic.co)" end) + " | "
       + (if $c == "elasticsearch" then "Elastic" elif ($c | IN("mysql")) then "Oracle"
          elif $c == "phpmyadmin" then "n/a" elif ($meta.signed // "adhoc") == "adhoc" then "ad-hoc"
          else "Developer ID" end) + " | "
       + (if $meta.notarized then "yes" elif ($c | IN("php","apache","redis")) then "no" else "–" end) + " |"' \
     "$out/manifest.json"
  echo
  if [[ -n "$unsigned" ]]; then
    echo "> **Unsigned build** (ad-hoc signatures): $unsigned — not for public distribution."
    echo
  fi
  echo "Elasticsearch is not redistributed: the app downloads the official elastic.co tarball on demand."
  echo
  "$build/third-party-licenses.sh" --release-notes
} >"$out/release-notes.md"

# ---------------------------------------------------------------- optional: decode with the app's RAMPCore
if [[ -n "${RAMPCTL:-}" ]]; then
  "$RAMPCTL" manifest validate "$out/manifest.json" --verify-files >&2 || die "rampctl rejected the assembled manifest"
fi

printf '%s\n' "$tag" >"$out/release-tag.txt"
[[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'tag=%s\n' "$tag" >>"$GITHUB_OUTPUT"
log "release payload → $out ($(du -sh "$out" | awk '{print $1}'))"
printf '%s\n' "$tag"
