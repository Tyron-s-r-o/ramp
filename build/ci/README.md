# RAMP CI — binaries + app releases

| File | Purpose |
|---|---|
| `.github/workflows/binaries.yml` | build all services (`build/build-all.sh`) on macOS 27 arm64 → sign → notarize → `manifest.json` → release payload; publish job gated by the `release` environment |
| `.github/workflows/app-release.yml` | archive/export/notarize/staple `RAMP.app`, Sparkle appcast (08-03) |
| `build/ci/setup-keychain.sh` | temp keychain from the Developer ID `.p12`, exports `SIGN_IDENTITY`/`SIGN_KEYCHAIN`/`NOTARY_KEY_P8`; `--check`, `--cleanup` |
| `build/ci/assemble-release.sh <dist> <out>` | copy + validate the payload (manifest rules = RAMPCore `Manifest.decode`), `packages.json`, `release-notes.md`, prints the tag |

Local dry run (identical to CI, nothing leaves the machine):

```bash
build/ci/assemble-release.sh build/dist /tmp/ramp-release
RAMPCTL=$(swift build --package-path app/Packages/RAMPCore --show-bin-path)/rampctl build/ci/assemble-release.sh build/dist /tmp/ramp-release2
```

## Repository layout (decision pending)

Prepared for **two repos + GitHub-hosted runner** (plan/06): app in `<owner>/ramp`, binaries in
`<owner>/ramp-binaries` (copy `build/`, `.github/workflows/binaries.yml`, `THIRD_PARTY_LICENSES.md`,
`app/Packages/RAMPCore` for the manifest check). Set `RAMP_BINARIES_REPO` in `build/versions.env`.
Stable manifest URL: `https://github.com/<owner>/ramp-binaries/releases/latest/download/manifest.json`
(the app resolves `${RAMP_DIST_BASE}` against it → packages must be assets of the same release).

Runner: repository variable `RAMP_BINARIES_RUNNER` (default `xcode-27`, hosted macOS 27 arm64, 6 h job limit;
`timeout-minutes: 350`). Self-hosted: give the runner a label (e.g. `ramp-mac`) and set the variable to it.

Caches: `build/.cache/src` (key `src-<hash versions.env>`), `build/.stage/{deps,.built,sys-pkgconfig}`
(key `deps-<os>-<arch>-<hash versions.env + build/deps/** + build/lib/**>`).

## Secrets (Settings › Secrets and variables › Actions) — created by the maintainer, never by CI

| Secret | How to produce |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Keychain Access › "Developer ID Application: … (S25RFUK37U)" › Export (with private key) → `base64 -i devid.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | the export password |
| `KEYCHAIN_PASSWORD` | random: `openssl rand -base64 24` |
| `NOTARY_KEY_ID` | App Store Connect › Users and Access › Integrations › App Store Connect API › key ID |
| `NOTARY_ISSUER_ID` | same page, Issuer ID |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<id>.p8` (the .p8 downloads only once) |
| `SPARKLE_PRIVATE_KEY` | app releases only (08-03): `generate_keys -x sparkle_private.key` → file content |

```bash
gh secret set DEVELOPER_ID_P12_BASE64 --repo <owner>/<repo> < <(base64 -i devid.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD --repo <owner>/<repo>
gh secret set KEYCHAIN_PASSWORD --repo <owner>/<repo> --body "$(openssl rand -base64 24)"
gh secret set NOTARY_KEY_ID --repo <owner>/<repo>
gh secret set NOTARY_ISSUER_ID --repo <owner>/<repo>
gh secret set NOTARY_KEY_P8_BASE64 --repo <owner>/<repo> < <(base64 -i AuthKey_XXXX.p8)
```

Environment `release` (Settings › Environments) with yourself as required reviewer — the publish jobs wait for it.

Without secrets (forks, PRs, scheduled runs) the build runs unsigned; an unsigned payload is only ever
published as a prerelease (never `latest`).
