# RAMP

**English** · [Slovensky](./README.sk.md)

RAMP is a native macOS app (SwiftUI, menu bar + window) that replaces MAMP PRO for local PHP development.
It installs and supervises Apache 2.4, PHP-FPM 7.3 and 8.1–8.5 (via `mod_proxy_fcgi`), MySQL 9.7 LTS,
Redis and phpMyAdmin, plus optional Elasticsearch — no Homebrew, no manual installs.

> **Status: feature-complete, not released yet.** The GUI, vhosts, PHP management, Elasticsearch, service
> updates, the MAMP PRO migration wizard and uninstall are all implemented (see [Status](#status)). What's
> left: a signed, notarized public release (Sparkle keys pending), and running the MAMP PRO migration against
> a real MAMP PRO installation. There is no downloadable build yet.

![RAMP main window](./docs/screenshots/main-window.png)

## Why

MAMP PRO runs PHP through `mod_fastcgi`, which forks PHP children from Apache; after a graceful restart
(e.g. saving settings) macOS kills those forks (`objc … fork() was called … Crashing instead`) and the
stack goes down. RAMP runs PHP-FPM as separate supervised processes and talks to them over Unix sockets,
so there is nothing to fork.

## Status

| Area | State |
|---|---|
| Relocatable arm64 builds (PHP 7.3/8.1–8.5 + extensions, Apache, Redis), MySQL/phpMyAdmin packaging, `manifest.json` | done |
| Swift core: layout, `ramp.json`, config generators, package installer, service supervisor | done |
| Vhost model, validation, `<VirtualHost>` generation, privileged `/etc/hosts` helper | done |
| php.ini layers, OPcache / APCu / Xdebug settings, extension catalog, phpMyAdmin | done |
| Elasticsearch: settings, install, start/stop, auto-stop scheduler | done |
| Full GUI (Services, Vhosts, PHP, Logs, Database, Settings, menu bar) | done |
| Hosts sync + vhost apply from the app, PHP manager, phpMyAdmin auto-login | done |
| Service updates with rollback, MAMP PRO import wizard, in-app uninstall | done |
| `rampctl` CLI (`install`, `up`, `status`, `reload`, `paths`, …) | done |
| MAMP PRO migration run against a real (non-synthetic) MAMP PRO installation | pending |
| Developer ID signing, notarization, public GitHub release | pending |
| Sparkle app updates | pending — needs signing keys |

## Requirements

- macOS 27 or newer, **Apple Silicon only**
- An administrator password once, to approve the helper that edits `/etc/hosts`
- Ports 80 (Apache), 3306 (MySQL) and 6379 (Redis) free — stop MAMP's servers first

## Install (planned)

1. Download the notarized `RAMP.zip` from the GitHub Releases page.
2. Move `RAMP.app` to `/Applications` and open it.
3. On first launch RAMP downloads the services listed in its manifest (checksums verified) into
   `~/Library/Application Support/RAMP`.
4. Approve the hosts helper in **System Settings › General › Login Items & Extensions**.

Until the first release, build from source (below).

## Migrating from MAMP PRO

An import wizard reads your MAMP PRO setup:

1. Reads MAMP PRO's Apache config: vhosts, aliases, document roots, PHP version per host; shows a dry-run plan.
2. Copies the MySQL data directory **without binlogs**, upgrades it 8.0 → 8.4 → 9.7 in RAMP's own datadir
   (falls back to per-database `mysqldump` if needed). Resumable.
3. Asks you to stop MAMP's MySQL while the copy runs.

MAMP's files and data are **never modified**. Your project folders are never touched.

The wizard is implemented and verified against a synthetic MySQL 8.0 → 9.7 upgrade; running it against a real
MAMP PRO installation is the last verification step before general use.

## Daily use

- **Menu bar**: service status, start/stop, quick actions (open localhost, logs folder), Xdebug/update
  indicator, OPcache clear and the vhost list.
- **Vhosts**: domain (e.g. `project.local`), aliases, document root, PHP version per vhost. The TLD is
  configurable (default `.local`); RAMP writes both `127.0.0.1` and `::1` into a marked block in `/etc/hosts`.
- **PHP**: one set of php.ini defaults for all versions → global override → per-version override.
  OPcache/APCu settings, Xdebug off by default (not even loaded) with a per-version toggle.
- **Logs**: one log per service in `~/Library/Logs/RAMP`.
- phpMyAdmin at `http://localhost/phpmyadmin`, with auto-login over the local socket.

![Vhost editor](./docs/screenshots/vhosts.png)

## Updates

- **Services**: checked against the manifest at launch; updates install side by side, switch the `current`
  symlink, health-check and roll back on failure. A dump is made before a MySQL major upgrade.
- **App**: Sparkle (signed appcast) — pending signing keys.

## Uninstall

In-app uninstall removes services, generated configs, databases (optional dump to the Desktop first), the
hosts block, the helper and the login item. **Project folders are never deleted.**

## Non-goals

- SSL / port 443 — not needed on localhost
- nginx — RAMP uses Apache, like typical production servers
- Intel Macs, Windows, Linux
- Homebrew or any other runtime dependency
- `mod_php` / `mod_fastcgi`

## Building from source

Binaries (needs Xcode 27 command line tools; Homebrew is used **only** for build-time tools):

```bash
build/build-all.sh              # deps → PHP → extensions → Apache → Redis → MySQL → phpMyAdmin → package → manifest
build/third-party-licenses.sh   # regenerate THIRD_PARTY_LICENSES.md from build/versions.env
```

See [build/README.md](./build/README.md) for individual steps. All versions and checksums are pinned in
[build/versions.env](./build/versions.env).

App:

```bash
cd app
xcodegen                         # generates RAMP.xcodeproj from project.yml
open RAMP.xcodeproj              # Debug scheme installs from the local build/dist/manifest.json
cd Packages/RAMPCore && swift test
swift run rampctl status         # or: install --manifest <url|path>, up, reload, paths
```

## Architecture

```
~/Library/Application Support/RAMP/
├── ramp.json               # all settings (vhosts, PHP, ports, TLD) — the single source of truth
├── php/8.3/current -> ../8.3.x   # installed packages, versioned, `current` symlink per branch
├── apache/ mysql/ redis/ phpmyadmin/
├── conf/                   # generated: apache/httpd.conf + vhosts/, php/<ver>/, mysql/<major>/my.cnf, redis/
├── run/                    # PHP-FPM + MySQL sockets, pid files
├── mysql-data/ redis-data/ elasticsearch-data/
└── www/default/            # http://localhost/
~/Library/Logs/RAMP/        # one log per service
```

- **RAMPCore** (Swift package): `Paths`, `ramp.json` model + `ConfigStore`, config generators, package
  installer (manifest, sha256, safe `.tar.xz` extraction), `ServiceSupervisor` (auto-restart with backoff).
- **RAMP.app**: SwiftUI app + embedded privileged helper (XPC, code-signature pinned) that can only rewrite
  RAMP's block in `/etc/hosts`.
- **rampctl**: CLI over the same core.
- **build/**: reproducible arm64 builds of every service; binaries live outside the app bundle so they update
  independently.

## License

RAMP is released under the [MIT License](./LICENSE). The services it installs are separate programs under
their own licenses (Apache-2.0, PHP License, GPLv2, AGPLv3, …) — see
[THIRD_PARTY_LICENSES.md](./THIRD_PARTY_LICENSES.md), including source-code links for copyleft components.
