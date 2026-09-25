import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// PHP branch install / uninstall: manifest support phases, first-launch default set, uninstall guards,
/// default pinning, MAMP import needs, and a sandbox install → uninstall round trip.
@Suite struct PHPBranchLifecycleTests {
    private let paths = GeneratorFixture.paths
    private let manifestURL = URL(string: "file:///Users/dev/RAMP/build/dist/manifest.json")!

    // MARK: Manifest

    private func manifest(php: [String: String]) throws -> Manifest {
        var branches: [String: Any] = [:]
        for (branch, extra) in php {
            var obj: [String: Any] = ["version": "\(branch).9", "url": "php-\(branch).9.tar.xz", "sha256": "aa", "size": 1]
            if !extra.isEmpty {
                let parts = extra.split(separator: " ")
                obj["support"] = String(parts[0])
                if parts.count > 1 { obj["eolDate"] = String(parts[1]) }
            }
            branches[branch] = obj
        }
        let json: [String: Any] = ["schema": 1, "components": [
            "php": branches,
            "apache": ["2.4": ["version": "2.4.68", "url": "a.tar.xz", "sha256": "bb"]],
            "phpmyadmin": ["5.2": ["version": "5.2.3", "url": "p.tar.xz", "sha256": "cc"]],
        ]]
        return try Manifest.decode(from: JSONSerialization.data(withJSONObject: json), manifestURL: manifestURL)
    }

    @Test func decodesSupportAndEOLDate() throws {
        let m = try manifest(php: ["8.5": "active 2029-12-31", "8.2": "security 2026-12-31", "7.4": "eol 2022-11-28",
                                   "8.1": "", "8.0": "bogus 2023-13-45"])
        #expect(m.entry(component: "php", branch: "8.5")?.support == .active)
        #expect(m.entry(component: "php", branch: "8.5")?.eolDate == "2029-12-31")
        #expect(m.entry(component: "php", branch: "8.2")?.support == .security)
        #expect(m.entry(component: "php", branch: "7.4")?.isEOL == true)
        #expect(m.entry(component: "php", branch: "7.4")?.eolDate == "2022-11-28")
        // Older manifest (no fields) / unknown value / impossible date → nil, still decodes.
        #expect(m.entry(component: "php", branch: "8.1")?.support == nil)
        #expect(m.entry(component: "php", branch: "8.1")?.eolDate == nil)
        #expect(m.entry(component: "php", branch: "8.0")?.support == nil)
        #expect(m.entry(component: "php", branch: "8.0")?.eolDate == nil)
        #expect(Manifest.validDate("2026-02-30") == nil)
        #expect(Manifest.validDate("2026-02-28") == "2026-02-28")
    }

    @Test func snakeCaseEOLDateAlsoDecodes() throws {
        let json = #"{"schema":1,"components":{"php":{"7.3":{"version":"7.3.33","url":"x.tar.xz","sha256":"a","support":"EOL","eol_date":"2021-12-06"}}}}"#
        let m = try Manifest.decode(from: Data(json.utf8), manifestURL: manifestURL)
        #expect(m.entry(component: "php", branch: "7.3")?.support == .eol)
        #expect(m.entry(component: "php", branch: "7.3")?.eolDate == "2021-12-06")
    }

    /// The shipped build/dist/manifest.json decodes with support phases for every PHP branch.
    @Test func shippedManifestHasSupportPhases() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/dist/manifest.json")
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return }
        let m = try Manifest.decode(from: data, manifestURL: url)
        for branch in m.branches(of: "php") {
            #expect(m.entry(component: "php", branch: branch)?.support != nil, "php \(branch)")
            #expect(m.entry(component: "php", branch: branch)?.eolDate != nil, "php \(branch)")
        }
        #expect(m.entry(component: "php", branch: "7.3")?.support == .eol)
        #expect(m.entry(component: "php", branch: "8.5")?.support == .active)
    }

    // MARK: Default set

    private func phpSlots(_ m: Manifest, required: Set<String> = []) -> [String] {
        PackageInstaller.defaultSlots(in: m, requiredPHP: required).filter { $0.component == "php" }.map(\.branch)
    }

    @Test func defaultSetSkipsEOLBranches() throws {
        let m = try manifest(php: ["8.5": "active", "8.4": "active", "8.3": "security", "8.1": "eol", "7.4": "eol"])
        #expect(phpSlots(m) == ["8.3", "8.4", "8.5"])
        #expect(PackageInstaller.defaultSlots(in: m).map(\.component) == ["apache", "phpmyadmin", "php", "php", "php"])
        // Branches the config needs (phpMyAdmin pinned, vhosts) come along even when EOL.
        #expect(phpSlots(m, required: ["7.4"]) == ["7.4", "8.3", "8.4", "8.5"])
    }

    @Test func defaultSetWithoutSupportInfoInstallsEverything() throws {
        let m = try manifest(php: ["8.3": "", "7.3": ""])
        #expect(phpSlots(m) == ["7.3", "8.3"])
        let allEOL = try manifest(php: ["7.3": "eol", "7.4": "eol"])
        #expect(phpSlots(allEOL) == ["7.4"])
    }

    // MARK: Uninstall guard

    private func vhost(_ domain: String, _ branch: String?, enabled: Bool = true) -> Vhost {
        Vhost(domain: domain, docroot: "/Users/t/www/\(domain)", phpBranch: branch, enabled: enabled)
    }

    @Test func uninstallBlocker() throws {
        var c = PHPConfDGeneratorTests.config   // 7.3 8.2 8.3 8.5, implicit default 8.5
        #expect(PHPManager.uninstallBlocker(config: c, paths: paths, branch: "8.2") == nil)
        #expect(PHPManager.uninstallBlocker(config: c, paths: paths, branch: "8.5")
                == .uninstallBlocked(branch: "8.5", isDefault: true, phpMyAdmin: false, vhosts: []))
        // Disabled vhosts count too (they would fail to render when re-enabled).
        c.vhosts = [vhost("off.local", "8.2", enabled: false), vhost("d.local", nil)]
        #expect(PHPManager.uninstallBlocker(config: c, paths: paths, branch: "8.2")
                == .uninstallBlocked(branch: "8.2", isDefault: false, phpMyAdmin: false, vhosts: ["off.local"]))
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.2") == nil)
        // phpMyAdmin pinned to a branch while disabled still blocks.
        c.installed["phpmyadmin"] = ["5.2": GeneratorFixture.pkg("5.2.3")]
        c.phpmyadmin.enabled = false
        c.phpmyadmin.phpBranch = "8.3"
        #expect(PHPManager.uninstallBlocker(config: c, paths: paths, branch: "8.3")
                == .uninstallBlocked(branch: "8.3", isDefault: false, phpMyAdmin: true, vhosts: []))
        // The only installed branch (even disabled) is never removed.
        var single = RampConfig()
        single.installed["php"] = ["7.4": GeneratorFixture.pkg("7.4.33")]
        single.php.branches["7.4"] = PHPBranchSettings(enabled: false)
        #expect(PHPManager.uninstallBlocker(config: single, paths: paths, branch: "7.4")
                == .uninstallBlocked(branch: "7.4", isDefault: true, phpMyAdmin: false, vhosts: []))
        let text = try #require(PHPManagerError.uninstallBlocked(branch: "8.2", isDefault: false, phpMyAdmin: false,
                                                                vhosts: ["a.local"]).errorDescription)
        #expect(text == "PHP 8.2 cannot be uninstalled: it is used by 1 vhost (a.local)")
    }

    @Test func pinDefaultsOnlyWhenTheNewBranchWouldBecomeHighest() {
        var c = PHPConfDGeneratorTests.config   // highest enabled 8.5
        c.installed["phpmyadmin"] = ["5.2": GeneratorFixture.pkg("5.2.3")]
        var lower = c
        PHPManager.pinDefaults(&lower, installing: "8.4")
        #expect(lower == c)
        var higher = c
        PHPManager.pinDefaults(&higher, installing: "8.6")
        #expect(higher.apache.defaultPHP == "8.5")
        #expect(higher.phpmyadmin.phpBranch == "8.5")
        var explicit = c
        explicit.apache.defaultPHP = "8.2"
        explicit.phpmyadmin.phpBranch = "8.3"
        PHPManager.pinDefaults(&explicit, installing: "8.6")
        #expect(explicit.apache.defaultPHP == "8.2" && explicit.phpmyadmin.phpBranch == "8.3")
    }

    @Test func offersListManifestBranchesWithState() throws {
        let m = try manifest(php: ["8.5": "active 2029-12-31", "8.2": "security", "7.3": "eol 2021-12-06", "7.2": "eol"])
        let offers = PHPManager.offers(manifest: m, config: PHPConfDGeneratorTests.config, paths: paths)
        #expect(offers.map(\.branch) == ["8.5", "8.2", "7.3", "7.2"])
        #expect(offers[0].isInstalled && offers[0].uninstallBlocker != nil)   // implicit default
        #expect(offers[1].installedVersion == "8.2.30" && offers[1].uninstallBlocker == nil)
        #expect(offers[2].isEOL && offers[2].eolDate == "2021-12-06")
        #expect(!offers[3].isInstalled && offers[3].version == "7.2.9")
    }

    // MARK: MAMP import

    @Test func mampImportOffersMissingBranches() {
        func candidate(_ domain: String, _ php: String?) -> ImportCandidate {
            ImportCandidate(vhost: Vhost(domain: domain, docroot: "/w/\(domain)"), source: .http, include: true,
                            issues: [], mampPHPVersion: php)
        }
        let candidates = [candidate("a.local", "7.4.33"), candidate("b.local", "7.3.33"), candidate("c.local", "8.3.14"),
                          candidate("d.local", "5.6.40"), candidate("e.local", nil), candidate("f.local", "8.1.2")]
        let needs = MAMPImportPlanner.installablePHPNeeds(candidates: candidates, installed: ["8.3", "8.5"],
                                                          offered: ["7.3", "7.4", "8.1", "8.3", "8.5"])
        // 7.3 → 7.4 (remap), 5.6 not offered, 8.3 installed.
        #expect(needs == [MAMPPHPNeed(branch: "8.1", domains: ["f.local"]),
                          MAMPPHPNeed(branch: "7.4", domains: ["a.local", "b.local"])])
        #expect(MAMPImportPlanner.installablePHPNeeds(candidates: candidates, installed: ["7.4", "8.1", "8.3"],
                                                      offered: ["7.3", "7.4", "8.1", "8.3"]).isEmpty)
    }
}

// MARK: - Sandbox integration

/// Real packages (FixtureBuilder archives), real installer, real renderer into a short /tmp root; the FPM side
/// is `FakePHPStack` (no processes).
@Suite(.serialized) struct PHPBranchInstallIntegrationTests {
    struct Env {
        let fx: FixtureBuilder
        let dir: URL
        let paths: Paths
        let store: ConfigStore
        let stack: FakePHPStack
        let manager: PHPManager
        let manifest: Manifest

        init() async throws {
            fx = try FixtureBuilder()
            var entries: [FixtureBuilder.Entry] = []
            for (branch, version, api) in [("8.3", "8.3.35", "20230831"), ("7.4", "7.4.33", "20190902"),
                                           ("8.5", "8.5.11", "20250925")] {
                let archive = try fx.package("php", version: version, topLevelDir: version,
                                             name: "php-\(version)-darwin-arm64.tar.xz")
                entries.append(.init(component: "php", branch: branch, version: version, archive: archive,
                                     extensionDirRel: "lib/php/extensions/no-debug-non-zts-\(api)"))
            }
            manifest = try fx.manifest(entries)
            // Short root: FPM socket paths must fit sun_path.
            dir = URL(filePath: "/tmp/rpi-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            paths = Paths(root: dir.appending(path: "r", directoryHint: .isDirectory),
                          logs: dir.appending(path: "l", directoryHint: .isDirectory))
            try paths.ensureDirectories()
            store = ConfigStore(paths: paths)
            let manifestURL = fx.manifestURL
            try await store.update { $0.manifestURL = manifestURL }
            stack = FakePHPStack(paths: paths, store: store)
            manager = PHPManager(store: store, stack: stack, paths: paths)
        }

        func cleanup() {
            fx.cleanup()
            try? FileManager.default.removeItem(at: dir)
        }

        func exists(_ url: URL) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
        }
    }

    @Test func installThenUninstallLeavesNothingBehind() async throws {
        let env = try await Env(); defer { env.cleanup() }
        let p = env.paths

        // Install 8.3 with progress (stream is finished by installBranch).
        let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
        let collector = Task { var stages: [InstallProgress.Stage] = []; for await e in progress { stages.append(e.stage) }; return stages }
        let record = try await env.manager.installBranch("8.3", progress: continuation)
        let stages = await collector.value
        #expect(record.version == "8.3.35")
        #expect(stages.first == .downloading)
        #expect(stages.last == .installed(record))
        #expect(env.exists(p.fpmConf(branch: "8.3")))
        #expect(await env.stack.applyCount == 1)

        // 7.4 (lower) → no pinning; enabled; its FPM config rendered.
        try await env.manager.installBranch("7.4")
        var config = try await env.store.load()
        #expect(config.apache.defaultPHP == nil)
        #expect(GeneratorSupport.enabledPHPBranches(config) == ["7.4", "8.3"])
        #expect(env.exists(p.fpmConf(branch: "7.4")))

        // Guards: default branch; a disabled vhost on 7.4.
        await #expect(throws: PHPManagerError.uninstallBlocked(branch: "8.3", isDefault: true, phpMyAdmin: false, vhosts: [])) {
            try await env.manager.uninstallBranch("8.3")
        }
        try await env.store.update {
            $0.vhosts = [Vhost(domain: "old.local", docroot: "/tmp/old", phpBranch: "7.4", enabled: false)]
        }
        await #expect(throws: PHPManagerError.uninstallBlocked(branch: "7.4", isDefault: false, phpMyAdmin: false,
                                                               vhosts: ["old.local"])) {
            try await env.manager.uninstallBranch("7.4")
        }
        #expect(env.exists(p.package(component: "php", version: "7.4.33")))
        try await env.store.update { $0.vhosts = []; $0.php.branches["7.4", default: PHPBranchSettings()].xdebug = .debug }

        // Leftovers the uninstall must remove (socket / pid / log / download), plus 8.3 ones it must keep.
        let fm = FileManager.default
        try fm.createDirectory(at: p.logs, withIntermediateDirectories: true)
        for url in [p.fpmSocket(branch: "7.4"), p.pidFile(service: "php7.4-fpm"), p.log("php7.4-fpm.log"),
                    p.log("php7.4-error.log"), p.log("php8.3-fpm.log")] {
            try Data().write(to: url)
        }
        #expect(env.exists(p.downloads.appending(path: "php-7.4.33-darwin-arm64.tar.xz")))

        try await env.manager.uninstallBranch("7.4")
        config = try await env.store.load()
        #expect(config.installed["php"]?["7.4"] == nil)
        #expect(config.php.branches["7.4"] == nil)
        for gone in [p.branchDir(component: "php", branch: "7.4"), p.package(component: "php", version: "7.4.33"),
                     p.phpConfDir(branch: "7.4"), p.fpmSocket(branch: "7.4"), p.pidFile(service: "php7.4-fpm"),
                     p.downloads.appending(path: "php-7.4.33-darwin-arm64.tar.xz"),
                     p.log("php7.4-fpm.log"), p.log("php7.4-error.log")] {
            #expect(!env.exists(gone), "\(gone.path(percentEncoded: false))")
        }
        for kept in [p.package(component: "php", version: "8.3.35"), p.current(component: "php", branch: "8.3"),
                     p.fpmConf(branch: "8.3"), p.log("php8.3-fpm.log"),
                     p.downloads.appending(path: "php-8.3.35-darwin-arm64.tar.xz")] {
            #expect(env.exists(kept), "\(kept.path(percentEncoded: false))")
        }

        // Reinstall works after the removal.
        #expect(try await env.manager.installBranch("7.4").version == "7.4.33")
    }

    @Test func newHighestBranchPinsTheCurrentDefault() async throws {
        let env = try await Env(); defer { env.cleanup() }
        try await env.manager.installBranch("8.3")
        try await env.manager.installBranch("8.5")
        let config = try await env.store.load()
        #expect(config.apache.defaultPHP == "8.3")
        #expect(GeneratorSupport.enabledPHPBranches(config) == ["8.3", "8.5"])
        // 8.5 is not the default → removable; 8.3 is.
        try await env.manager.uninstallBranch("8.5")
        #expect(try await env.store.load().installed["php"]?.keys.sorted() == ["8.3"])
    }

    @Test func installErrorsAndIdempotence() async throws {
        let env = try await Env(); defer { env.cleanup() }
        await #expect(throws: PHPManagerError.branchNotOffered("9.9")) { try await env.manager.installBranch("9.9") }
        await #expect(throws: PHPManagerError.branchNotOffered("x")) { try await env.manager.installBranch("x") }
        await #expect(throws: GeneratorError.phpBranchNotInstalled("8.3")) { try await env.manager.uninstallBranch("8.3") }

        try await env.manager.installBranch("8.3")
        try await env.manager.installBranch("7.4")
        try await env.manager.setBranchEnabled(branch: "7.4", enabled: false)
        // Installed but disabled → install only re-enables (no download).
        try FileManager.default.removeItem(at: env.fx.manifestURL)
        let again = try await env.manager.installBranch("7.4")
        #expect(again.version == "7.4.33")
        #expect(try await env.store.load().php.branches["7.4"]?.enabled ?? true)

        try await env.store.update { $0.manifestURL = nil }
        await #expect(throws: PHPManagerError.noManifest) { try await env.manager.installBranch("8.5") }
    }

    @Test func detachedStackRefusesToRemoveARunningFPM() async throws {
        let env = try await Env(); defer { env.cleanup() }
        let detached = DetachedPHPStack(paths: env.paths, store: env.store)
        try await detached.stopFPMForRemoval(branch: "7.4")   // no pid file → fine
        try FileManager.default.createDirectory(at: env.paths.supervisorRunDir, withIntermediateDirectories: true)
        try Data("\(getpid())\n".utf8).write(to: env.paths.pidFile(service: "php7.4-fpm"))
        await #expect(throws: PHPManagerError.fpmRunningElsewhere(branch: "7.4", pid: getpid())) {
            try await detached.stopFPMForRemoval(branch: "7.4")
        }
    }
}
