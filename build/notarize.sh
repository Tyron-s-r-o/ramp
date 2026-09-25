#!/usr/bin/env bash
# notarize.sh — submit the self-built Mach-O of service packages to Apple's notary service.
#
# Usage:
#   build/notarize.sh [options] <dist/pkg.tar.xz>…
#
# Options:
#   --submit                 actually submit (default: DRY-RUN — verify signatures, build the zip,
#                            print the exact notarytool command, exit 0)
#   --profile <name>         keychain profile from `xcrun notarytool store-credentials <name> …`
#   --api-key <file.p8>      App Store Connect API key (with --key-id and --issuer) — CI style
#   --key-id <id>            API key ID
#   --issuer <uuid>          API issuer ID
#   --keep                   keep the temp work dir (zips) and print its path
#   -h, --help               this text
#
# Credentials may also come from the environment (never written to disk except a temp .p8, mode 0600,
# deleted on exit):
#   NOTARY_PROFILE                                     = --profile
#   NOTARY_KEY_P8 (path) | NOTARY_KEY_P8_BASE64 (CI secret), NOTARY_KEY_ID, NOTARY_ISSUER_ID  = --api-key …
#
# Why a zip: notarytool accepts only zip / flat pkg / UDIF dmg, not .tar.xz. Every signed Mach-O of the
# package is copied (relative paths preserved) into <pkg>-notarize.zip purely for submission; Apple
# records each binary's cdhash. Stand-alone Mach-O cannot be stapled — Gatekeeper looks the ticket up
# online. The distributed artifact stays the .tar.xz (unchanged by this script).
#
# Preconditions per binary (else: fail with the list — ad-hoc / "Apple Development" cannot be notarized):
#   Authority = "Developer ID Application: …", hardened runtime flag, secure timestamp.
# Vendor packages (mysql = Oracle, elasticsearch = Elastic, phpmyadmin = no Mach-O) are skipped.
#
# On Accepted: "notarized": "<submission id>" is added to <pkg>.json next to the package (manifest
# metadata). On Invalid: `notarytool log` → build/.stage/logs/notary-<pkg>.json, exit 1.
#
# CI (08-02 .github/workflows/binaries.yml, after build/ci/setup-keychain.sh wrote the key):
#   build/notarize.sh --submit --api-key "$RUNNER_TEMP/notary.p8" \
#       --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" build/dist/{php,apache,redis}-*.tar.xz
# Local (after the human checkpoint created the profile):
#   build/notarize.sh --submit --profile ramp-notary /tmp/ramp-signed/php-8.3.*.tar.xz
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${RAMP_STAGE_DIR:-$here/.stage}/logs"

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
log()  { printf '[%s] notarize: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

submit=0 keep=0
profile="${NOTARY_PROFILE:-}" key="${NOTARY_KEY_P8:-}" key_id="${NOTARY_KEY_ID:-}" issuer="${NOTARY_ISSUER_ID:-}"
pkgs=()
while (($#)); do
  case "$1" in
    --submit) submit=1 ;;
    --keep) keep=1 ;;
    --profile) profile="${2:?--profile needs a value}"; shift ;;
    --api-key) key="${2:?--api-key needs a file}"; shift ;;
    --key-id) key_id="${2:?--key-id needs a value}"; shift ;;
    --issuer) issuer="${2:?--issuer needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) pkgs+=("$1") ;;
  esac
  shift
done
((${#pkgs[@]})) || { usage >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/ramp-notarize.XXXXXX")"
cleanup() {
  [[ -n "${tmp_key:-}" ]] && rm -f "$tmp_key"
  if ((keep)); then log "work dir kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- credentials → notarytool auth args
auth=() auth_shown=()
if [[ -z "$key" && -n "${NOTARY_KEY_P8_BASE64:-}" ]]; then
  tmp_key="$(mktemp "${TMPDIR:-/tmp}/ramp-notary.XXXXXX")"; chmod 600 "$tmp_key"
  printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode >"$tmp_key" || die "NOTARY_KEY_P8_BASE64 is not valid base64"
  key="$tmp_key"
fi
if [[ -n "$profile" ]]; then
  auth=(--keychain-profile "$profile"); auth_shown=("${auth[@]}")
elif [[ -n "$key" ]]; then
  [[ -n "$key_id" && -n "$issuer" ]] || die "--api-key needs --key-id and --issuer (or NOTARY_KEY_ID / NOTARY_ISSUER_ID)"
  [[ -f "$key" ]] || die "API key file not found: $key"
  auth=(--key "$key" --key-id "$key_id" --issuer "$issuer")
  auth_shown=(--key "<p8>" --key-id "$key_id" --issuer "$issuer")
else
  ((submit)) && die "--submit needs credentials: --profile <name> or --api-key/--key-id/--issuer (see --help)"
  auth_shown=(--keychain-profile "<profile>")
fi

# ---------------------------------------------------------------- per package
# check_binary FILE → prints a reason when FILE is not notarizable, nothing when OK
check_binary() {
  local sig; sig="$(codesign -dvv "$1" 2>&1)" || { echo "unsigned/invalid"; return; }
  local why=()
  local who; who="$(awk -F= '/^Authority=/{print $2; exit}' <<<"$sig")"
  [[ "$who" == "Developer ID Application: "* ]] || why+=("not Developer ID (${who:-ad-hoc})")
  grep -q 'flags=.*runtime' <<<"$sig" || why+=("no hardened runtime")
  grep -q '^Timestamp=' <<<"$sig" || why+=("no secure timestamp")
  ((${#why[@]} == 0)) || { local IFS=';'; echo "${why[*]}"; }
}

failed=0 not_ready=()
for pkg in "${pkgs[@]}"; do
  [[ -f "$pkg" ]] || die "no such package: $pkg"
  pkg="$(cd "$(dirname "$pkg")" && pwd)/$(basename "$pkg")"
  base="$(basename "$pkg" .tar.xz)"          # <comp>-<ver>-darwin-arm64
  comp="${base%%-*}"
  case "$comp" in
    mysql|elasticsearch|phpmyadmin) log "skip $base — vendor-signed / no Mach-O (not re-signed by RAMP)"; continue ;;
  esac

  x="$work/$base"; mkdir -p "$x/extract" "$x/submit/$base"
  /usr/bin/tar -xf "$pkg" -C "$x/extract"
  top="$(find "$x/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$top" ]] || die "$base: empty archive"

  n=0 bad=0 sample=""
  while IFS= read -r -d '' f; do
    [[ "$(file -b "$f")" == Mach-O* ]] || continue
    rel="${f#"$top"/}"; n=$((n+1))
    reason="$(check_binary "$f")"
    if [[ -n "$reason" ]]; then
      bad=$((bad+1)); ((bad <= 15)) && not_ready+=("$base: $rel — $reason")
    fi
    mkdir -p "$x/submit/$base/$(dirname "$rel")"
    cp -p "$f" "$x/submit/$base/$rel"
    [[ -z "$sample" && "$(file -b "$f")" == *executable* ]] && sample="$f"
  done < <(find "$top" -type f -print0 | LC_ALL=C sort -z)
  ((bad > 15)) && not_ready+=("$base: … and $((bad-15)) more")
  ((n)) || { log "$base: no Mach-O — nothing to notarize"; continue; }

  zip="$x/$base-notarize.zip"
  ditto -c -k --keepParent "$x/submit/$base" "$zip"
  log "$base: $n Mach-O → $(basename "$zip") ($(( $(stat -f %z "$zip") / 1048576 )) MiB)"
  if ((bad)); then failed=$((failed+1)); continue; fi

  cmd=(xcrun notarytool submit "$zip" --wait --output-format json)
  if ((submit == 0)); then
    log "DRY-RUN — would run (zip kept only with --keep):"
    printf ' %q' "${cmd[@]}" "${auth_shown[@]}" >&2; printf '\n' >&2
    continue
  fi

  log "$base: submitting to Apple notary service (waits for the verdict)…"
  out="$("${cmd[@]}" "${auth[@]}" 2>"$x/submit.err")" || true
  id="$(jq -r '.id // empty' <<<"$out" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$id" ]] || { cat "$x/submit.err" >&2; die "$base: notarytool submit failed (no submission id)"; }
  log "$base: submission $id → $status"
  if [[ "$status" != Accepted ]]; then
    mkdir -p "$LOG_DIR"
    xcrun notarytool log "$id" "${auth[@]}" "$LOG_DIR/notary-$base.json" >/dev/null 2>&1 || true
    log "$base: notary log → $LOG_DIR/notary-$base.json"
    failed=$((failed+1)); continue
  fi
  meta="$(dirname "$pkg")/$base.json"
  if [[ -f "$meta" ]]; then
    jq --arg id "$id" '. + {notarized: $id}' "$meta" >"$meta.part" && mv -f "$meta.part" "$meta"
    log "$base: recorded notarized=$id in $(basename "$meta")"
  fi
  if [[ -n "$sample" ]]; then
    spctl -a -t exec -vv "$sample" 2>&1 | sed "s|^$top/|  |" >&2 || log "$base: spctl did not accept ${sample#"$top"/} yet (ticket propagation can take a minute)"
  fi
done

if ((${#not_ready[@]})); then
  log "NOT notarizable — sign with a \"Developer ID Application\" identity (SIGN_IDENTITY=… build/package.sh):"
  printf '  ✗ %s\n' "${not_ready[@]}" >&2
fi
((failed == 0)) || die "$failed package(s) failed"
((submit)) && log "all packages notarized" || log "dry-run OK (nothing sent to Apple)"
