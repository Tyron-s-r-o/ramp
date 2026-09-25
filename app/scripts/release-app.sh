#!/usr/bin/env bash
# release-app.sh — build a distributable RAMP.app: archive → Developer ID export → (strip Sparkle XPC) →
# verify → zip → notarize + staple → Sparkle appcast (EdDSA-signed).
#
# Usage:
#   app/scripts/release-app.sh --version 1.0.0 --build 42 [options]
#
# Options:
#   --version X.Y.Z            CFBundleShortVersionString (MARKETING_VERSION)
#   --build N                  CFBundleVersion, monotonic integer (RAMP_BUILD_NUMBER) — Sparkle compares it
#   --out DIR                  output dir (default: <repo>/dist-app) → RAMP-<ver>.zip, RAMP-<ver>.md, appcast.xml
#   --derived-data DIR         xcodebuild -derivedDataPath (default: app/DerivedData/release)
#   --dry-run                  local test without Developer ID / keys: Apple Development signing, "development"
#                              export (fallback: the archived app), no notarization, unsigned appcast skipped
#   --submit                   notarize (notarytool submit --wait) + staple + re-zip; without it the commands are printed
#   --notarize-profile NAME    keychain profile (xcrun notarytool store-credentials NAME …)
#   --api-key P8 --key-id ID --issuer UUID   App Store Connect API key (CI); env NOTARY_KEY_P8 / NOTARY_KEY_ID /
#                              NOTARY_ISSUER_ID are used when the flags are absent
#   --ed-key-file FILE|-       Sparkle EdDSA private key for generate_appcast ("-" = stdin, CI secret);
#                              omitted → generate_appcast uses the key in your login keychain
#   --download-url-prefix URL  where the zip will be downloadable (default:
#                              https://github.com/$RAMP_APP_REPO/releases/download/v<ver>/)
#   --previous-appcast URL|FILE  existing appcast.xml to extend (keeps older items; default: none)
#   --keep-xpc                 keep Sparkle's XPC services (not needed: RAMP is not sandboxed)
#   -h, --help
#
# Environment: RAMP_APP_REPO (default OWNER/ramp — must be set for real releases), SIGN_KEYCHAIN (CI temp
# keychain from build/ci/setup-keychain.sh), RAMP_SPARKLE_PUBLIC_KEY (overrides Distribution.xcconfig).
#
# Preflight (real release): a "Developer ID Application" identity exists; SUPublicEDKey in
# app/RAMP/Distribution.xcconfig is not the TODO placeholder; feed URL / repo are not OWNER placeholders;
# a dirty git tree is only a warning. Nothing is uploaded — publishing is app-release.yml / `gh release`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
repo="$(cd "$app_dir/.." && pwd)"
TEAM=S25RFUK37U

log()  { printf '[%s] release-app: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

version="" build="" out="$repo/dist-app" dd="$app_dir/DerivedData/release"
dry=0 submit=0 keep_xpc=0 ed_key="" url_prefix="" prev_appcast=""
profile="${NOTARY_PROFILE:-}" api_key="${NOTARY_KEY_P8:-}" key_id="${NOTARY_KEY_ID:-}" issuer="${NOTARY_ISSUER_ID:-}"
while (($#)); do
  case "$1" in
    --version) version="${2:?}"; shift ;;
    --build) build="${2:?}"; shift ;;
    --out) out="${2:?}"; shift ;;
    --derived-data) dd="${2:?}"; shift ;;
    --dry-run) dry=1 ;;
    --submit) submit=1 ;;
    --notarize-profile) profile="${2:?}"; shift ;;
    --api-key) api_key="${2:?}"; shift ;;
    --key-id) key_id="${2:?}"; shift ;;
    --issuer) issuer="${2:?}"; shift ;;
    --ed-key-file) ed_key="${2:?}"; shift ;;
    --download-url-prefix) url_prefix="${2:?}"; shift ;;
    --previous-appcast) prev_appcast="${2:?}"; shift ;;
    --keep-xpc) keep_xpc=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "--version X.Y[.Z] required"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || die "--build <positive integer> required"
((dry && submit)) && die "--dry-run and --submit are exclusive"

# the EdDSA key from stdin is read now (and only kept in memory) so no later command can consume stdin
ed_key_data=""
if [[ "$ed_key" == - ]]; then ed_key_data="$(cat)"; [[ -n "$ed_key_data" ]] || die "--ed-key-file -: empty stdin"; fi

app_repo="${RAMP_APP_REPO:-OWNER/ramp}"
xcconfig="$app_dir/RAMP/Distribution.xcconfig"
xc_value() { awk -F' = ' -v k="$1" '$1==k {print $2; exit}' "$xcconfig"; }
pubkey="${RAMP_SPARKLE_PUBLIC_KEY:-$(xc_value RAMP_SPARKLE_PUBLIC_KEY)}"
feed="$(xc_value RAMP_APPCAST_URL)"
[[ -n "$url_prefix" ]] || url_prefix="https://github.com/$app_repo/releases/download/v$version/"

# ---------------------------------------------------------------- preflight
for t in xcodegen xcodebuild ditto codesign; do command -v "$t" >/dev/null || die "$t not found"; done
problems=()
if ((dry)); then
  identity="Apple Development"
else
  identity="Developer ID Application"
  ids="$(security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"})"
  grep -q '"Developer ID Application: ' <<<"$ids" \
    || problems+=("no 'Developer ID Application' identity in the keychain (Xcode › Settings › Accounts › Manage Certificates)")
  [[ -n "$pubkey" && "$pubkey" != TODO* ]] || problems+=("SUPublicEDKey is the placeholder — put generate_keys' public key into $xcconfig (RAMP_SPARKLE_PUBLIC_KEY)")
  [[ "$feed" != *OWNER* ]] || problems+=("RAMP_APPCAST_URL in $xcconfig still contains OWNER")
  [[ "$url_prefix" != *OWNER* ]] || problems+=("download URL prefix contains OWNER — set RAMP_APP_REPO=<owner>/<repo> or --download-url-prefix")
  if ((submit)) && [[ -z "$profile" && -z "$api_key" ]]; then problems+=("--submit needs --notarize-profile or --api-key/--key-id/--issuer"); fi
fi
if ((${#problems[@]})); then printf '  ✗ %s\n' "${problems[@]}" >&2; die "preflight failed"; fi
if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then warn "git working tree is not clean"; fi
((dry)) && warn "DRY-RUN: Apple Development signing, no notarization, appcast not signed — NOT distributable"

mkdir -p "$out"; out="$(cd "$out" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ramp-release.XXXXXX")"
tmp_key=""
cleanup() { [[ -n "$tmp_key" ]] && rm -f "$tmp_key"; rm -rf "$work"; }
trap cleanup EXIT

# ---------------------------------------------------------------- archive
log "xcodegen generate"
(cd "$app_dir" && xcodegen generate --quiet) </dev/null
archive="$work/RAMP.xcarchive"
sign_overrides=()
if ((dry)); then
  sign_overrides=(CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development" OTHER_CODE_SIGN_FLAGS=)
elif [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
  sign_overrides=("OTHER_CODE_SIGN_FLAGS=--timestamp --keychain $SIGN_KEYCHAIN")
fi
log "archive RAMP $version ($build) — $identity"
xcodebuild archive -project "$app_dir/RAMP.xcodeproj" -scheme RAMP -configuration Release \
  -archivePath "$archive" -derivedDataPath "$dd" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" RAMP_BUILD_NUMBER="$build" \
  ${RAMP_SPARKLE_PUBLIC_KEY:+RAMP_SPARKLE_PUBLIC_KEY="$RAMP_SPARKLE_PUBLIC_KEY"} \
  "${sign_overrides[@]+"${sign_overrides[@]}"}" </dev/null >"$work/archive.log" 2>&1 \
  || { tail -n 40 "$work/archive.log" >&2; die "archive failed (log above)"; }
grep -E ' warning: ' "$work/archive.log" | grep -v appintentsmetadataprocessor | sort -u | sed 's/^/  /' >&2 || true

# ---------------------------------------------------------------- export
export_dir="$work/export"
if ((dry)); then
  opts="$work/ExportOptions-dev.plist"
  plutil -create xml1 "$opts"
  plutil -insert method -string development "$opts"
  plutil -insert teamID -string "$TEAM" "$opts"
  plutil -insert signingStyle -string automatic "$opts"
else
  opts="$app_dir/ExportOptions.plist"
fi
log "export ($(plutil -extract method raw "$opts"))"
if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" -exportPath "$export_dir" \
     </dev/null >"$work/export.log" 2>&1; then
  if ((dry)); then
    warn "development export failed ($(grep -m1 -E 'error' "$work/export.log" || echo see log)) — using the archived app"
    mkdir -p "$export_dir"; ditto "$archive/Products/Applications/RAMP.app" "$export_dir/RAMP.app"
  else
    tail -n 40 "$work/export.log" >&2; die "export failed"
  fi
fi
app="$export_dir/RAMP.app"
[[ -d "$app" ]] || die "no RAMP.app in the export"

# ---------------------------------------------------------------- strip Sparkle XPC services (not sandboxed)
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if ((keep_xpc == 0)) && [[ -d "$sparkle/Versions/B/XPCServices" ]]; then
  appsig="$(codesign -dvv "$app" 2>&1)"   # capture first: awk's early exit would SIGPIPE codesign (pipefail)
  signer="$(awk -F= '/^Authority=/{print $2; exit}' <<<"$appsig")"
  [[ -n "$signer" ]] || die "cannot read the app's signing identity"
  ts=(--timestamp); ((dry)) && ts=(--timestamp=none)
  kc=(); [[ -n "${SIGN_KEYCHAIN:-}" ]] && kc=(--keychain "$SIGN_KEYCHAIN")
  rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
  codesign --force --sign "$signer" --options runtime "${ts[@]}" "${kc[@]+"${kc[@]}"}" "$sparkle"
  codesign --force --sign "$signer" --options runtime "${ts[@]}" "${kc[@]+"${kc[@]}"}" \
    --preserve-metadata=entitlements,requirements,flags "$app"
  log "stripped Sparkle XPCServices, re-signed framework + app ($signer)"
fi

# ---------------------------------------------------------------- verify signatures
codesign --verify --deep --strict --verbose=1 "$app" 2>"$work/verify.log" || { cat "$work/verify.log" >&2; die "codesign --verify --deep --strict failed"; }
bad=0
check() {  # PATH LABEL
  local sig team; sig="$(codesign -dvv "$1" 2>&1)" || { log "  ✗ $2: unsigned"; bad=$((bad+1)); return; }
  team="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$sig")"
  [[ "$team" == "$TEAM" ]] || { log "  ✗ $2: TeamIdentifier=$team"; bad=$((bad+1)); }
  grep -q 'flags=.*runtime' <<<"$sig" || { log "  ✗ $2: no hardened runtime"; bad=$((bad+1)); }
  if ((dry == 0)); then
    grep -q '^Authority=Developer ID Application: ' <<<"$sig" || { log "  ✗ $2: not Developer ID"; bad=$((bad+1)); }
    grep -q '^Timestamp=' <<<"$sig" || { log "  ✗ $2: no secure timestamp"; bad=$((bad+1)); }
  fi
}
check "$app" RAMP.app
check "$app/Contents/MacOS/sk.tyron.ramp.hostshelper" hostshelper
check "$sparkle" Sparkle.framework
check "$sparkle/Versions/B/Autoupdate" Sparkle/Autoupdate
check "$sparkle/Versions/B/Updater.app" Sparkle/Updater.app
ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
if ((dry == 0)) && grep -q 'get-task-allow' <<<"$ents"; then log "  ✗ RAMP.app has get-task-allow"; bad=$((bad+1)); fi
((bad == 0)) || die "$bad signature problem(s)"
plist="$app/Contents/Info.plist"
got_v="$(plutil -extract CFBundleShortVersionString raw "$plist")" got_b="$(plutil -extract CFBundleVersion raw "$plist")"
[[ "$got_v" == "$version" && "$got_b" == "$build" ]] || die "Info.plist has $got_v ($got_b), expected $version ($build)"
log "signatures OK (app, helper, Sparkle framework/Autoupdate/Updater.app: team $TEAM, runtime)"

# ---------------------------------------------------------------- zip (+ notarize/staple)
zip="$out/RAMP-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
auth=() auth_shown=()
if [[ -n "$profile" ]]; then auth=(--keychain-profile "$profile"); auth_shown=("${auth[@]}")
elif [[ -n "$api_key" ]]; then
  [[ -n "$key_id" && -n "$issuer" ]] || die "--api-key needs --key-id and --issuer"
  auth=(--key "$api_key" --key-id "$key_id" --issuer "$issuer"); auth_shown=(--key "<p8>" --key-id "$key_id" --issuer "$issuer")
else auth_shown=(--keychain-profile ramp-notary); fi

if ((submit)); then
  log "notarizing $(basename "$zip") (waits for Apple)…"
  res="$(xcrun notarytool submit "$zip" --wait --output-format json "${auth[@]}" </dev/null)" || true
  id="$(jq -r '.id // empty' <<<"$res" 2>/dev/null || true)"; status="$(jq -r '.status // empty' <<<"$res" 2>/dev/null || true)"
  [[ -n "$id" ]] || die "notarytool submit failed: $res"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" "${auth[@]}" "$out/notary-$version.json" </dev/null >/dev/null 2>&1 || true
    die "notarization $id: $status (log: $out/notary-$version.json)"
  fi
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  rm -f "$zip"; ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  spctl -a -t exec -vv "$app" 2>&1 | tee "$work/spctl.txt" >&2
  grep -q 'Notarized Developer ID' "$work/spctl.txt" || die "spctl does not report 'Notarized Developer ID'"
  log "notarized ($id) + stapled"
else
  log "not notarized — with --submit this runs:"
  printf '    xcrun notarytool submit %q --wait %s\n    xcrun stapler staple RAMP.app && ditto -c -k --sequesterRsrc --keepParent RAMP.app %q\n    spctl -a -t exec -vv RAMP.app\n' \
    "$zip" "${auth_shown[*]}" "$zip" >&2
fi

# ---------------------------------------------------------------- release notes + appcast
notes="$out/RAMP-$version.md"
if [[ -f "$app_dir/CHANGELOG.md" ]]; then
  awk -v v="$version" '$0 ~ "^## " {p = ($2 == v)} p && $0 !~ "^## " {print}' "$app_dir/CHANGELOG.md" \
    | sed -e '/./,$!d' >"$notes"
fi
[[ -s "$notes" ]] || { warn "no '## $version' section in app/CHANGELOG.md"; printf 'RAMP %s\n' "$version" >"$notes"; }

gen="$dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$gen" ]] || die "generate_appcast not found at $gen (Sparkle SPM artifacts)"
if [[ -n "$prev_appcast" ]]; then
  if [[ -f "$prev_appcast" ]]; then cp "$prev_appcast" "$out/appcast.xml"
  else curl -fsSL "$prev_appcast" -o "$out/appcast.xml" || warn "could not fetch previous appcast $prev_appcast — starting a new feed"; fi
fi
gen_args=(--download-url-prefix "$url_prefix" --embed-release-notes --maximum-deltas 0 "$out")
if ((dry)); then
  log "appcast NOT generated in dry-run (needs the EdDSA private key) — release run:"
  printf '    %q --ed-key-file <key|-> %s\n' "$gen" "${gen_args[*]}" >&2
else
  if [[ "$ed_key" == - ]]; then
    printf '%s' "$ed_key_data" | "$gen" --ed-key-file - "${gen_args[@]}"
  elif [[ -n "$ed_key" ]]; then
    "$gen" --ed-key-file "$ed_key" "${gen_args[@]}" </dev/null
  else
    "$gen" "${gen_args[@]}" </dev/null   # login keychain key (generate_keys default account)
  fi
  grep -q 'sparkle:edSignature=' "$out/appcast.xml" || die "appcast.xml has no sparkle:edSignature"
  log "appcast.xml signed ($(grep -c '<item>' "$out/appcast.xml") item(s))"
fi

log "done → $out"
ls -l "$out" >&2
