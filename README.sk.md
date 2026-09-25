# RAMP

[English](./README.md) · **Slovensky**

RAMP je natívna macOS appka (SwiftUI, menu bar + okno), ktorá nahrádza MAMP PRO pri lokálnom vývoji v PHP.
Nainštaluje a stráži Apache 2.4, PHP-FPM 7.3 a 8.1–8.5 (cez `mod_proxy_fcgi`), MySQL 9.7 LTS, Redis
a phpMyAdmin, voliteľne aj Elasticsearch — bez Homebrew a bez ručnej inštalácie.

> **Stav: funkčne hotové, zatiaľ nevydané.** GUI, vhosty, PHP manažment, Elasticsearch, aktualizácie služieb,
> sprievodca migráciou z MAMP PRO aj odinštalovanie sú implementované (pozri [Stav](#stav)). Ostáva: podpísané
> a notarizované verejné vydanie (chýbajú Sparkle kľúče) a spustenie migrácie z MAMP PRO na reálnej inštalácii.
> Stiahnuteľná verzia zatiaľ neexistuje.

![Hlavné okno RAMP](./docs/screenshots/main-window.png)

## Prečo

MAMP PRO spúšťa PHP cez `mod_fastcgi`, ktorý forkuje PHP procesy z Apache; po graceful reštarte (napr. po
uložení nastavení) ich macOS zabije (`objc … fork() was called … Crashing instead`) a celý stack spadne.
RAMP spúšťa PHP-FPM ako samostatné strážené procesy a komunikuje s nimi cez Unix sockety — nie je čo forkovať.

## Stav

| Oblasť | Stav |
|---|---|
| Relocatable arm64 buildy (PHP 7.3/8.1–8.5 + rozšírenia, Apache, Redis), balíky MySQL/phpMyAdmin, `manifest.json` | hotové |
| Swift jadro: layout, `ramp.json`, generátory konfigov, inštalátor balíkov, supervisor služieb | hotové |
| Model vhostov, validácia, generovanie `<VirtualHost>`, privilegovaný helper pre `/etc/hosts` | hotové |
| Vrstvy php.ini, nastavenia OPcache / APCu / Xdebug, katalóg rozšírení, phpMyAdmin | hotové |
| Elasticsearch: nastavenia, inštalácia, štart/stop, plánovač auto-stopu | hotové |
| Kompletné GUI (Služby, Vhosty, PHP, Logy, Databáza, Nastavenia, menu bar) | hotové |
| Synchronizácia hosts + aplikovanie vhostov z appky, PHP manager, auto-login do phpMyAdmin | hotové |
| Aktualizácie služieb s rollbackom, sprievodca importom z MAMP PRO, odinštalovanie z appky | hotové |
| CLI `rampctl` (`install`, `up`, `status`, `reload`, `paths`, …) | hotové |
| Spustenie migrácie z MAMP PRO na reálnej (nie syntetickej) inštalácii | plánované |
| Developer ID podpis, notarizácia, verejné vydanie na GitHube | plánované |
| Aktualizácie appky cez Sparkle | plánované — chýbajú podpisové kľúče |

## Požiadavky

- macOS 27 alebo novší, **len Apple Silicon**
- Jednorazovo heslo administrátora na schválenie helpera, ktorý upravuje `/etc/hosts`
- Voľné porty 80 (Apache), 3306 (MySQL) a 6379 (Redis) — najprv zastav servery MAMPu

## Inštalácia (plánované)

1. Stiahni notarizovaný `RAMP.zip` zo stránky GitHub Releases.
2. Presuň `RAMP.app` do `/Applications` a spusti ju.
3. Pri prvom spustení RAMP stiahne služby podľa manifestu (s overením checksumov) do
   `~/Library/Application Support/RAMP`.
4. Schváľ hosts helper v **Systémové nastavenia › Všeobecné › Položky prihlásenia a rozšírenia**.

Do prvého vydania si appku zostav zo zdrojákov (nižšie).

## Migrácia z MAMP PRO

Sprievodca naimportuje nastavenie MAMP PRO:

1. Načíta Apache konfig MAMP PRO: vhosty, aliasy, docrooty, PHP verziu per host; ukáže plán nanečisto (dry-run).
2. Skopíruje dátový priečinok MySQL **bez binlogov** a upgradne ho 8.0 → 8.4 → 9.7 vo vlastnom datadire RAMP
   (v prípade potreby záloha cez `mysqldump` po databázach). Dá sa prerušiť a pokračovať.
3. Počas kopírovania ťa vyzve zastaviť MySQL v MAMPe.

Súbory a dáta MAMPu sa **nikdy nemenia**. Projektové priečinky sa nikdy nemenia.

Sprievodca je implementovaný a overený na syntetickom upgrade MySQL 8.0 → 9.7; spustenie na reálnej inštalácii
MAMP PRO je posledný overovací krok pred bežným použitím.

## Každodenné použitie

- **Menu bar**: stav služieb, štart/stop, rýchle akcie (otvoriť localhost, priečinok s logmi), indikátor
  Xdebugu/aktualizácie, vyčistenie OPcache a zoznam vhostov.
- **Vhosty**: doména (napr. `project.local`), aliasy, docroot, PHP verzia per vhost. TLD je nastaviteľná
  (default `.local`); RAMP zapisuje `127.0.0.1` aj `::1` do označeného bloku v `/etc/hosts`.
- **PHP**: jedna sada php.ini defaultov pre všetky verzie → globálny override → override per verzia.
  Nastavenia OPcache/APCu, Xdebug predvolene vypnutý (ani nenačítaný) s prepínačom per verzia.
- **Logy**: jeden log na službu v `~/Library/Logs/RAMP`.
- phpMyAdmin na `http://localhost/phpmyadmin`, s auto-loginom cez lokálny socket.

![Editor vhostu](./docs/screenshots/vhosts.png)

## Aktualizácie

- **Služby**: kontrola voči manifestu pri štarte; nová verzia sa nainštaluje vedľa starej, prepne sa symlink
  `current`, prebehne health-check a pri chybe rollback. Pred major upgradom MySQL sa spraví dump.
- **Appka**: Sparkle (podpísaný appcast) — čaká sa na podpisové kľúče.

## Odinštalovanie

Odinštalovanie z appky zmaže služby, vygenerované konfigy, databázy (voliteľne najprv dump na Plochu),
blok v hosts, helper a login item. **Projektové priečinky sa nikdy nemažú.**

## Čo RAMP nerobí

- SSL / port 443 — na localhoste zbytočné
- nginx — RAMP používa Apache ako bežné produkčné servery
- Intel Macy, Windows, Linux
- Homebrew ani iné runtime závislosti
- `mod_php` / `mod_fastcgi`

## Build zo zdrojákov

Binárky (treba Xcode 27 command line tools; Homebrew sa používa **len** na nástroje počas buildu):

```bash
build/build-all.sh              # deps → PHP → rozšírenia → Apache → Redis → MySQL → phpMyAdmin → balíky → manifest
build/third-party-licenses.sh   # pregeneruje THIRD_PARTY_LICENSES.md z build/versions.env
```

Jednotlivé kroky: [build/README.md](./build/README.md). Všetky verzie a checksumy sú pinnuté v
[build/versions.env](./build/versions.env).

Appka:

```bash
cd app
xcodegen                         # vygeneruje RAMP.xcodeproj z project.yml
open RAMP.xcodeproj              # Debug schéma inštaluje z lokálneho build/dist/manifest.json
cd Packages/RAMPCore && swift test
swift run rampctl status         # alebo: install --manifest <url|cesta>, up, reload, paths
```

## Architektúra

```
~/Library/Application Support/RAMP/
├── ramp.json               # všetky nastavenia (vhosty, PHP, porty, TLD) — jediný zdroj pravdy
├── php/8.3/current -> ../8.3.x   # nainštalované balíky, verzované, symlink `current` per vetva
├── apache/ mysql/ redis/ phpmyadmin/
├── conf/                   # generované: apache/httpd.conf + vhosts/, php/<ver>/, mysql/<major>/my.cnf, redis/
├── run/                    # sockety PHP-FPM + MySQL, pid súbory
├── mysql-data/ redis-data/ elasticsearch-data/
└── www/default/            # http://localhost/
~/Library/Logs/RAMP/        # jeden log na službu
```

- **RAMPCore** (Swift package): `Paths`, model `ramp.json` + `ConfigStore`, generátory konfigov, inštalátor
  balíkov (manifest, sha256, bezpečné rozbalenie `.tar.xz`), `ServiceSupervisor` (auto-restart s backoffom).
- **RAMP.app**: SwiftUI appka + vložený privilegovaný helper (XPC, pinnutý na podpis appky), ktorý vie len
  prepísať blok RAMP v `/etc/hosts`.
- **rampctl**: CLI nad tým istým jadrom.
- **build/**: reprodukovateľné arm64 buildy všetkých služieb; binárky sú mimo app bundlu, aby sa dali
  aktualizovať nezávisle.

## Licencia

RAMP je vydaný pod [licenciou MIT](./LICENSE). Služby, ktoré inštaluje, sú samostatné programy s vlastnými
licenciami (Apache-2.0, PHP License, GPLv2, AGPLv3, …) — pozri
[THIRD_PARTY_LICENSES.md](./THIRD_PARTY_LICENSES.md) vrátane odkazov na zdrojový kód copyleft komponentov.
