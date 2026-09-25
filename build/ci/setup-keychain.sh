#!/usr/bin/env bash
# setup-keychain.sh — CI signing setup (GitHub Actions macOS runner). Never run by the executor locally
# except --help / --check.
#
#   build/ci/setup-keychain.sh             create a temporary keychain with the Developer ID Application
#                                          identity; write the notary API key; export env for later steps
#   build/ci/setup-keychain.sh --check     exit 0 when all signing secrets are present, 1 otherwise (touches nothing)
#   build/ci/setup-keychain.sh --cleanup   delete the temporary keychain + key file (run with if: always())
#   build/ci/setup-keychain.sh --help
#
# Inputs (GitHub secrets → env):
#   DEVELOPER_ID_P12_BASE64    base64 of the exported "Developer ID Application" certificate + private key (.p12)
#   DEVELOPER_ID_P12_PASSWORD  the .p12 export password
#   KEYCHAIN_PASSWORD          any random string (protects the temporary keychain)
#   NOTARY_KEY_P8_BASE64       base64 of the App Store Connect API key (.p8)   — optional here; needed to notarize
#   (NOTARY_KEY_ID / NOTARY_ISSUER_ID are passed to notarize.sh / release-app.sh directly)
#
# Outputs (appended to $GITHUB_ENV, or printed as `export …` lines when not in Actions):
#   SIGN_IDENTITY  SHA-1 of the Developer ID Application identity   (build/package.sh, sign.sh)
#   SIGN_KEYCHAIN  path of the temporary keychain                     (codesign --keychain)
#   NOTARY_KEY_P8  path of the .p8 (mode 0600) in $RUNNER_TEMP        (notarize.sh, release-app.sh)
#
# A missing secret fails fast with a clear message BEFORE anything is created, so forks / PRs (no secrets)
# can take the unsigned path: the workflow calls --check first.
set -euo pipefail

tmp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
kc="$tmp_root/ramp-signing.keychain-db"
p8="$tmp_root/ramp-notary.p8"
log() { printf 'setup-keychain: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
emit() {  # NAME VALUE → $GITHUB_ENV or stdout
  if [[ -n "${GITHUB_ENV:-}" ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV"
  else printf 'export %s=%q\n' "$1" "$2"; fi
}

missing_secrets() {
  local v out=()
  for v in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD KEYCHAIN_PASSWORD; do
    [[ -n "${!v:-}" ]] || out+=("$v")
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
  --check)
    m="$(missing_secrets)"
    if [[ -n "$m" ]]; then log "signing secrets missing: $(echo $m) → unsigned build"; exit 1; fi
    log "signing secrets present"; exit 0 ;;
  --cleanup)
    if [[ -f "$kc" ]]; then security delete-keychain "$kc" 2>/dev/null || true; log "deleted $kc"; fi
    rm -f "$p8"
    exit 0 ;;
  "") ;;
  *) die "unknown argument '$1' (see --help)" ;;
esac

m="$(missing_secrets)"
[[ -z "$m" ]] || die "missing secret(s): $(echo $m) — add them in GitHub › Settings › Secrets (see build/ci/README.md). Nothing was created."
command -v security >/dev/null || die "security(1) not found — macOS runner required"

p12="$(mktemp "$tmp_root/ramp-devid.XXXXXX")"; chmod 600 "$p12"
trap 'rm -f "$p12"' EXIT
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode >"$p12" || die "DEVELOPER_ID_P12_BASE64 is not valid base64"

[[ -f "$kc" ]] && security delete-keychain "$kc" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$kc"
security set-keychain-settings -lut 21600 "$kc"          # auto-lock after 6 h (job max)
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$kc"
security import "$p12" -k "$kc" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null
# allow codesign to use the key without a UI prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$kc" >/dev/null
# prepend to the user search list (keep the existing ones: login / System for the Apple intermediate CAs)
existing=()
while IFS= read -r k; do k="${k//\"/}"; k="${k#"${k%%[![:space:]]*}"}"; [[ -n "$k" && "$k" != "$kc" ]] && existing+=("$k"); done \
  < <(security list-keychains -d user)
security list-keychains -d user -s "$kc" "${existing[@]+"${existing[@]}"}"

ids="$(security find-identity -v -p codesigning "$kc")"   # parse a captured copy (no SIGPIPE under pipefail)
sha="$(awk '/"Developer ID Application: /{print $2; exit}' <<<"$ids")"
[[ -n "$sha" ]] || { printf '%s\n' "$ids" >&2; die "no valid 'Developer ID Application' identity in the .p12"; }
name="$(awk -v s="$sha" '$2==s{sub(/^[^"]*"/,""); sub(/"$/,""); print; exit}' <<<"$ids")"
log "identity: $name ($sha)"
emit SIGN_IDENTITY "$sha"
emit SIGN_KEYCHAIN "$kc"

if [[ -n "${NOTARY_KEY_P8_BASE64:-}" ]]; then
  (umask 077; printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode >"$p8") || die "NOTARY_KEY_P8_BASE64 is not valid base64"
  chmod 600 "$p8"
  emit NOTARY_KEY_P8 "$p8"
  log "notary API key → $p8 (0600)"
else
  log "NOTARY_KEY_P8_BASE64 not set — signing only, notarization will be skipped"
fi
