#!/usr/bin/env bash
# fetch-elasticvue.sh — Elasticvue (Elasticsearch web GUI, MIT) static web build → out/elasticvue/<ver>/.
#
# Upstream publishes no plain web asset (only desktop apps + browser-extension zips; the extension build
# uses hash routing, absolute /assets URLs and never reads predefined clusters). So the pinned, sha256-
# verified GitHub tag archive is built here with npm (build-time only; node >= 24, `npm ci` against the
# upstream package-lock.json):
#   VITE_APP_BUILD_MODE=docker      → CORS hints + predefined-cluster import ("default clusters")
#   VITE_APP_PUBLIC_PATH=/elasticvue/ → served by Apache at http://localhost/elasticvue/ (history routing)
# Two source patches (verified below, the build fails if upstream moved the code):
#   1. predefined clusters are read from <base>/api/default_clusters.json (upstream: absolute /api/…,
#      i.e. outside the /elasticvue alias). RAMP writes that file (ElasticvueConfigGenerator).
#   2. the footer update check (GET update.elasticvue.com with a per-browser UUID) is disabled —
#      RAMP ships Elasticvue updates through its own manifest.
# Output: index.html + assets/ + images/, LICENSE; source maps dropped.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ver="$ELASTICVUE_VERSION"
out="$OUT_DIR/elasticvue/$ver"
if is_built "elasticvue-$ver" && [[ -f "$out/index.html" ]]; then
  log "elasticvue $ver already present ($out) — FORCE=1 to rebuild"
else
  command -v npm >/dev/null 2>&1 || die "elasticvue: npm not found (node >= 24 is a build-time requirement)"
  tarball="$(fetch elasticvue "$ELASTICVUE_URL" "$ELASTICVUE_SHA256")"
  tmp="$(mktemp -d "$WORK_DIR/elasticvue.XXXXXX")"
  src="$(extract "$tarball" "$tmp")"

  # patch 1: default clusters relative to the public path
  f="$src/src/composables/components/predefinedclusters/PredefinedClusters.ts"
  grep -q "fetch('/api/default_clusters.json')" "$f" || die "elasticvue: predefined-clusters fetch not found in $f"
  sed -i '' "s|fetch('/api/default_clusters.json')|fetch(import.meta.env.BASE_URL + 'api/default_clusters.json')|" "$f"
  grep -q "import.meta.env.BASE_URL + 'api/default_clusters.json'" "$f" || die "elasticvue: patch 1 failed"
  # patch 2: no update check
  f="$src/src/components/base/AppFooter.vue"
  grep -q '<update-check v-if="!buildConfig.tauri"' "$f" || die "elasticvue: update-check not found in $f"
  sed -i '' 's|<update-check v-if="!buildConfig.tauri"|<update-check v-if="false"|' "$f"
  grep -q '<update-check v-if="false"' "$f" || die "elasticvue: patch 2 failed"

  run_logged "elasticvue-$ver-npm-ci" bash -c "cd '$src' && npm ci --no-audit --no-fund --ignore-scripts"
  run_logged "elasticvue-$ver-build" bash -c \
    "cd '$src' && NODE_ENV=production VITE_APP_BUILD_MODE=docker VITE_APP_PUBLIC_PATH=/elasticvue/ npm run build"

  rm -rf "$out"; mkdir -p "$out"
  cp -R "$src/dist/." "$out/"
  cp "$src/LICENSE" "$out/LICENSE"
  find "$out" -name '*.map' -type f -delete
  rm -rf "$tmp"
  mark_built "elasticvue-$ver"
fi

# smoke: layout, public path baked in, both patches in the bundle, no update endpoint
[[ -f "$out/index.html" && -d "$out/assets" && -f "$out/LICENSE" ]] || die "elasticvue: unexpected layout in $out"
grep -q 'src="/elasticvue/assets/' "$out/index.html" || die "elasticvue: index.html not built for /elasticvue/"
grep -rqs 'api/default_clusters.json' "$out/assets" || die "elasticvue: predefined-clusters code missing"
if grep -rqs "fetch(\"/api/default_clusters.json\")\|fetch('/api/default_clusters.json')" "$out/assets"; then
  die "elasticvue: bundle still fetches /api/default_clusters.json (patch 1 not applied)"
fi
if grep -rqs 'update.elasticvue.com/api/update' "$out/assets"; then
  log "elasticvue: note — update URL string still present in the bundle (component not rendered)"
fi
grep -rqs "$ver" "$out/assets" || die "elasticvue: bundle does not mention version $ver"
log "elasticvue $ver OK ($out)"
