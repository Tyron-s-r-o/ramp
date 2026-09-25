#!/usr/bin/env bash
# manifest.sh — dist/manifest.json from the package metadata written by package.sh (+ Elasticsearch).
#
#   build/manifest.sh                                   # URLs: ${RAMP_DIST_BASE}/<file> (literal placeholder)
#   DIST_BASE_URL=https://github.com/…/download/v1 build/manifest.sh   # absolute URLs (Phase 8 releases)
#   OFFLINE=1 build/manifest.sh                         # skip the elastic.co sha512/size cross-check
#
# Schema 1 (decoded by app RAMPCore Install/Manifest.swift):
#   {schema:1, generated, components:{<component>:{<major.minor>:{version,url,sha256,size,file,
#     [php: extension_dir_rel, extensions, api, opcache, support, eolDate]}},
#     elasticsearch:{"9.5":{version,url,sha512,size}}}}
#   php support = active|security|eol, eolDate = YYYY-MM-DD (versions.env PHP<NN>_SUPPORT / PHP<NN>_EOL; optional —
#   older manifests without them still decode)
# The app resolves "${RAMP_DIST_BASE}" and relative URLs against the manifest's own directory.
#
# Every package's sha256 + size is recomputed from the file (sidecars are not trusted). If several
# packages share a branch (e.g. an old version left in dist/), the highest version wins (warning).
# Re-runnable: always rewrites manifest.json atomically.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/common.sh"

placeholder='${RAMP_DIST_BASE}'
base="${DIST_BASE_URL:-$placeholder}"
base="${base%/}"
out="$DIST_DIR/manifest.json"

shopt -s nullglob
metas=("$DIST_DIR"/*-darwin-arm64.json)
((${#metas[@]})) || die "no package metadata in $DIST_DIR — run build/package.sh first"

entries=()
for m in "${metas[@]}"; do
  file="$(jq -r .file "$m")"
  pkg="$DIST_DIR/$file"
  [[ -f "$pkg" ]] || die "$m names missing package $file"
  sha="$(sha256_of "$pkg")"; size="$(stat -f %z "$pkg")"
  [[ "$sha" == "$(jq -r .sha256 "$m")" ]] || die "$file: sha256 differs from package.sh metadata — re-run package.sh"
  # PHP support phase from versions.env (PHP<NN>_SUPPORT / PHP<NN>_EOL); empty → field omitted
  support=""; eol=""
  if [[ "$(jq -r .component "$m")" == php ]]; then
    key="PHP$(jq -r .branch "$m" | tr -d .)"
    support_var="${key}_SUPPORT"; eol_var="${key}_EOL"
    support="${!support_var:-}"; eol="${!eol_var:-}"
    [[ -z "$support" || "$support" =~ ^(active|security|eol)$ ]] || die "$support_var=$support (active|security|eol)"
    [[ -z "$eol" || "$eol" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "$eol_var=$eol (YYYY-MM-DD)"
    [[ -n "$support" ]] || log "WARN no $support_var in versions.env — manifest entry without support phase"
  fi
  entries+=("$(jq -c --arg u "$base/$file" --arg s "$sha" --argjson z "$size" --arg sup "$support" --arg eol "$eol" \
    '{component, branch, entry: ({version, url:$u, sha256:$s, size:$z, file}
       + (if .component == "php" then {extension_dir_rel, extensions, api, opcache} else {} end)
       + (if $sup != "" then {support:$sup} else {} end)
       + (if $eol != "" then {eolDate:$eol} else {} end))}' "$m")")
done

# Elasticsearch: official elastic.co artifact, not repacked (upstream publishes SHA-512 only)
es_size=null
if [[ "${OFFLINE:-0}" != 1 ]]; then
  pub="$(curl -fsSL --retry 2 "$ES_URL.sha512" | awk '{print $1}')" || die "cannot fetch $ES_URL.sha512 (OFFLINE=1 to skip)"
  [[ "$pub" == "$ES_SHA512" ]] || die "elasticsearch sha512 mismatch: versions.env $ES_SHA512 vs elastic.co $pub"
  es_size="$(curl -fsSIL --retry 2 "$ES_URL" | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v+0}')"
  [[ "$es_size" =~ ^[1-9][0-9]*$ ]] || es_size=null
fi
es_branch="$(awk -F. '{print $1"."$2}' <<<"$ES_VERSION")"
entries+=("$(jq -nc --arg b "$es_branch" --arg v "$ES_VERSION" --arg u "$ES_URL" --arg s "$ES_SHA512" \
  --argjson z "$es_size" '{component:"elasticsearch", branch:$b, entry:{version:$v, url:$u, sha512:$s, size:$z}}')")

generated="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "${entries[@]}" | jq -s --arg g "$generated" '
  # highest version per component/branch
  def vkey: .entry.version | [splits("[.-]") | (tonumber? // 0)];
  group_by([.component, .branch])
  | map(sort_by(vkey) | last)
  | reduce .[] as $e ({}; .[$e.component][$e.branch] = $e.entry)
  | {schema: 1, generated: $g, components: .}' >"$out.part"

# warn about shadowed versions (same branch, older)
printf '%s\n' "${entries[@]}" | jq -rs 'group_by([.component,.branch])[] | select(length>1)
  | "\(.[0].component) \(.[0].branch): \(map(.entry.version)|join(", ")) — highest kept"' \
  | while IFS= read -r w; do log "WARN duplicate branch $w"; done

mv -f "$out.part" "$out"
log "manifest → $out"
jq -r '.components | to_entries[] | .key as $c | .value | to_entries[]
       | "  \($c) \(.key): \(.value.version)  \(.value.size // "?") B"' "$out" >&2
