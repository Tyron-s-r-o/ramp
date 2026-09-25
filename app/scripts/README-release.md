# Releasing RAMP.app (08-03)

RAMP.app updates itself with **Sparkle 2.10** (EdDSA-signed appcast); services update through the binaries
manifest (07-02, `.github/workflows/binaries.yml`).

## Configuration — `app/RAMP/Distribution.xcconfig`

| Setting | Info.plist key | Status |
|---|---|---|
| `RAMP_APPCAST_URL` | `SUFeedURL` | TODO: `https://github.com/<owner>/ramp/releases/latest/download/appcast.xml` |
| `RAMP_SPARKLE_PUBLIC_KEY` | `SUPublicEDKey` | TODO: public key from `generate_keys` |
| `RAMP_MANIFEST_URL` | `RAMPDefaultManifestURL` | TODO: `…/<owner>/ramp-binaries/releases/latest/download/manifest.json` |
| `RAMP_BUILD_NUMBER` | `CFBundleVersion` | set per release (`--build`) |

Fixed in `app/RAMP/Info.plist`: `SUEnableAutomaticChecks YES`, `SUScheduledCheckInterval 86400`,
`SUVerifyUpdateBeforeExtraction YES`, `SURequireSignedFeed YES`. The updater is not started in DEBUG builds or
while the URL/key are placeholders (`AppUpdater.disabledReason`). `RAMPDefaultManifestURL` is only used when
ramp.json has no `manifestURL` (fresh installs; `RAMP_DEV_MANIFEST` wins in development).

Signing: Debug = Apple Development (automatic); Release = `Developer ID Application`, manual, `--timestamp`
(project.yml `settings.configs.Release`). The hosts helper's XPC requirement pins identifier + Team ID
(`anchor apple generic … leaf[subject.OU] = S25RFUK37U`) and therefore accepts Developer ID builds unchanged.
After an update the launch-time `HelperUpgradeCheck` compares the running helper's `version()` with the bundled
`RAMPHostsHelper.version` and re-registers on a mismatch — **bump `RAMPHostsHelper.version` whenever the helper changes.**

## One-time setup (maintainer)

```bash
# 1. Developer ID Application certificate (Account Holder/Admin): Xcode › Settings › Accounts › Manage Certificates › +
security find-identity -v -p codesigning | grep "Developer ID Application"
# 2. Notary credentials (App Store Connect API key, "Developer" role)
xcrun notarytool store-credentials ramp-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
# 3. Sparkle EdDSA keys (private key → login keychain; prints the public key)
DD=app/DerivedData/release   # after one build/resolve; any DerivedData with SourcePackages works
$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys            # → put the public key into Distribution.xcconfig
$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private.key
gh secret set SPARKLE_PRIVATE_KEY --repo <owner>/ramp < sparkle_private.key && rm -P sparkle_private.key
# back up the private key (losing it = existing installs can never update again)
```

## Release

```bash
# local test (no Developer ID / keys needed; not distributable)
app/scripts/release-app.sh --dry-run --version 0.0.1 --build 1 --out /tmp/ramp-app

# real release, locally
RAMP_APP_REPO=<owner>/ramp app/scripts/release-app.sh --version 1.0.0 --build 1 \
  --submit --notarize-profile ramp-notary --out dist-app/ \
  --previous-appcast https://github.com/<owner>/ramp/releases/latest/download/appcast.xml
gh release create v1.0.0 dist-app/RAMP-1.0.0.zip dist-app/appcast.xml --notes-file dist-app/RAMP-1.0.0.md --latest

# or in CI: add a "## 1.0.0" section to app/CHANGELOG.md, then
git tag v1.0.0 && git push origin v1.0.0   # app-release.yml → approve the "release" environment
```

`release-app.sh` steps: preflight → `xcodegen generate` → `xcodebuild archive` (Release) → `-exportArchive`
(`app/ExportOptions.plist`, method `developer-id`) → strip Sparkle `XPCServices` (RAMP is not sandboxed) and
re-sign framework + app → `codesign --verify --deep --strict` + Team ID / runtime / Developer ID / timestamp
checks for app, helper, Sparkle framework, Autoupdate, Updater.app → `ditto` zip → (`--submit`) notarytool +
`stapler staple` + re-zip + `spctl` "Notarized Developer ID" → release notes from `app/CHANGELOG.md` →
`generate_appcast --ed-key-file … --embed-release-notes` → `appcast.xml` with `sparkle:edSignature`.

Verify a published release:

```bash
curl -fsSLO https://github.com/<owner>/ramp/releases/download/v1.0.0/RAMP-1.0.0.zip
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));curl;" RAMP-1.0.0.zip
ditto -x -k RAMP-1.0.0.zip . && spctl -a -vv RAMP.app      # → accepted, source=Notarized Developer ID
```
