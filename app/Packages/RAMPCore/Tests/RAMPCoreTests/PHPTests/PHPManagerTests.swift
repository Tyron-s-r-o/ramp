import Foundation
import Testing
@testable import RAMPCore

/// Stack double: really renders/writes/prunes into the temp root and maps changed files with
/// `StackController.affectedServices`; FPM preflight is simulated by `reject(config) -> branch?`.
actor FakePHPStack: PHPStackControl {
    let paths: Paths
    let store: ConfigStore
    var reject: @Sendable (RampConfig) -> String? = { _ in nil }
    var running: Set<String> = []
    private(set) var applyCount = 0
    private(set) var fpmReloads: [String] = []

    init(paths: Paths, store: ConfigStore) {
        self.paths = paths
        self.store = store
    }

    func set(reject: @escaping @Sendable (RampConfig) -> String?) { self.reject = reject }
    func set(running: Set<String>) { self.running = running }

    func applyConfigChanges() async throws -> ConfigApplyReport {
        applyCount += 1
        let config = try await store.load()
        var report = ConfigApplyReport()
        let files = try ConfigRenderer.renderAll(config: config, paths: paths)
        let writer = ConfigWriter(paths: paths)
        report.changed = try writer.write(files)
        let produced = Set(files.map { $0.path.standardizedFileURL })
        for m in ConfigRenderer.managedDirectories(config: config, paths: paths) {
            report.changed.formUnion(try writer.prune(directory: m.dir, keeping: produced, extension: m.ext))
        }
        let affected = StackController.affectedServices(changed: report.changed, paths: paths)
        let rejected = reject(config)
        for id in affected.reload.sorted(by: { $0.name < $1.name }) {
            if case .phpFPM(let b) = id, b == rejected {
                report.preflightFailed[id] = "ERROR: simulated php-fpm -t failure"
                report.errors[id] = "configuration test failed"
            } else {
                report.reloaded.append(id)
            }
        }
        return report
    }

    func reloadFPM(branch: String) async throws {
        guard running.contains(branch) else { throw PHPManagerError.notRunning(branch: branch) }
        fpmReloads.append(branch)
    }
}

@Suite(.serialized) struct PHPManagerTests {
    struct Env {
        let dir: URL
        let paths: Paths
        let store: ConfigStore
        let stack: FakePHPStack
        let manager: PHPManager

        /// Short root (FPM socket paths must fit sun_path). php 7.3/8.2/8.3/8.5 + apache/mysql/redis.
        init(_ edit: (inout RampConfig) -> Void = { _ in }) async throws {
            dir = URL(filePath: "/tmp/rpm-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            paths = Paths(root: dir.appending(path: "r", directoryHint: .isDirectory),
                          logs: dir.appending(path: "l", directoryHint: .isDirectory))
            try paths.ensureDirectories()
            store = ConfigStore(paths: paths)
            var config = PHPConfDGeneratorTests.config
            edit(&config)
            try await store.save(config)
            stack = FakePHPStack(paths: paths, store: store)
            manager = PHPManager(store: store, stack: stack, paths: paths)
            _ = try await stack.applyConfigChanges()   // baseline files on disk
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }

        func ini(_ branch: String) throws -> String {
            try String(contentsOf: paths.phpIni(branch: branch), encoding: .utf8)
        }
    }

    @Test func branchOverrideReloadsOnlyThatBranch() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let report = try await env.manager.setIniOverride(scope: .branch("8.3"), key: "memory_limit", value: "2048M")
        #expect(report.reloaded == [.phpFPM("8.3")])
        #expect(try env.ini("8.3").contains("memory_limit = 2048M") || env.ini("8.3").contains("memory_limit=2048M"))
        #expect(try !env.ini("8.2").contains("2048M"))
        let eff = try await env.manager.effectiveIni(branch: "8.3").first { $0.key == "memory_limit" }
        #expect(eff == IniDirective(key: "memory_limit", value: "2048M", source: .branch))

        // Removing the override restores the base value, again only on 8.3.
        let removed = try await env.manager.setIniOverride(scope: .branch("8.3"), key: "memory_limit", value: nil)
        #expect(removed.reloaded == [.phpFPM("8.3")])
        #expect(try await env.manager.effectiveIni(branch: "8.3").first { $0.key == "memory_limit" }?.source == .base)
    }

    @Test func globalOverrideReloadsEveryBranchButNotApache() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let report = try await env.manager.setIniOverride(scope: .global, key: "max_input_vars", value: "5000")
        #expect(Set(report.reloaded) == [.phpFPM("7.3"), .phpFPM("8.2"), .phpFPM("8.3"), .phpFPM("8.5")])
        #expect(!report.reloaded.contains(.apache))
        #expect(!report.changed.contains(env.paths.apacheConf.standardizedFileURL))
    }

    @Test func noOpChangeDoesNotApply() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let before = await env.stack.applyCount
        let report = try await env.manager.setXdebug(branch: "8.3", mode: .off)
        #expect(report == ConfigApplyReport())
        #expect(await env.stack.applyCount == before)
    }

    @Test func rejectedPreflightRollsBack() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        await env.stack.set(reject: { $0.php.branches["8.3"]?.iniOverrides["memory_limit"] == "999M" ? "8.3" : nil })
        let previous = try await env.store.load()
        await #expect(throws: PHPManagerError.fpmRejected(branch: "8.3", output: "ERROR: simulated php-fpm -t failure")) {
            try await env.manager.setIniOverride(scope: .branch("8.3"), key: "memory_limit", value: "999M")
        }
        #expect(try await env.store.load() == previous)
        #expect(try !env.ini("8.3").contains("999M"))   // previous files re-applied
    }

    @Test func invalidChangesFailBeforeSaving() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let previous = try await env.store.load()
        let applies = await env.stack.applyCount

        // 7.3 ships no phalcon.
        await #expect(throws: GeneratorError.extensionUnavailable(branch: "7.3", name: "phalcon")) {
            try await env.manager.setExtension(branch: "7.3", name: "phalcon", enabled: true)
        }
        // Protected key.
        await #expect(throws: GeneratorError.self) {
            try await env.manager.setIniOverride(scope: .branch("8.3"), key: "extension", value: "foo")
        }
        await #expect(throws: GeneratorError.self) {
            try await env.manager.setAPCu(branch: "8.3", APCuOptions(shmSize: "lots"))
        }
        await #expect(throws: PHPManagerError.unknownExtension("xdebug")) {
            try await env.manager.setExtension(branch: "8.3", name: "xdebug", enabled: true)
        }
        await #expect(throws: GeneratorError.phpBranchNotInstalled("8.1")) {
            try await env.manager.setXdebug(branch: "8.1", mode: .debug)
        }
        #expect(try await env.store.load() == previous)
        #expect(await env.stack.applyCount == applies)
    }

    @Test func xdebugAndExtensionsAreBranchScoped() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let r1 = try await env.manager.setXdebug(branch: "8.3", mode: .profile)
        #expect(r1.reloaded == [.phpFPM("8.3")])
        #expect(try await env.manager.xdebugEnabledBranches() == ["8.3"])
        #expect(FileManager.default.fileExists(atPath: env.paths.logs.appending(path: "xdebug").path(percentEncoded: false)))
        let r2 = try await env.manager.setXdebug(branch: "8.3", mode: .off)
        #expect(r2.reloaded == [.phpFPM("8.3")])
        #expect(r2.changed.contains(env.paths.phpConfD(branch: "8.3").appending(path: "90-xdebug.ini").standardizedFileURL))
        #expect(try await env.manager.xdebugEnabledBranches().isEmpty)

        let r3 = try await env.manager.setExtension(branch: "8.2", name: "phalcon", enabled: false)
        #expect(r3.reloaded == [.phpFPM("8.2")])
        #expect(try await !env.manager.enabledExtensions(branch: "8.2").contains("phalcon"))
        let r4 = try await env.manager.setOPcache(branch: "8.5", OPcacheOptions(profile: .performance))
        #expect(r4.reloaded == [.phpFPM("8.5")])
    }

    @Test func probeFillsUnknownExtensionsOnce() async throws {
        let env = try await Env { $0.installed["php"]!["8.2"]!.extensions = nil }
        defer { env.cleanup() }
        let config = try await env.store.load()
        let rel = try #require(config.installed["php"]?["8.2"]?.extensionDirRel)
        let extDir = env.paths.current(component: "php", branch: "8.2").appending(path: rel, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        for f in ["apcu.so", "phalcon.so", "xdebug.so", "opcache.so", "notes.txt"] {
            FileManager.default.createFile(atPath: extDir.appending(path: f).path(percentEncoded: false), contents: Data())
        }
        #expect(PHPExtensionProbe.scan(branch: "8.2", config: config, paths: env.paths) == ["apcu", "phalcon", "xdebug"])
        #expect(PHPExtensionProbe.scan(branch: "8.1", config: config, paths: env.paths) == nil)

        #expect(try await env.manager.availableExtensions(branch: "8.2") == ["apcu", "phalcon", "xdebug"])
        #expect(try await env.store.load().installed["php"]?["8.2"]?.extensions == ["apcu", "phalcon", "xdebug"])
        // Persisted: a later dir change is not rescanned.
        try FileManager.default.removeItem(at: extDir.appending(path: "phalcon.so"))
        #expect(try await env.manager.availableExtensions(branch: "8.2").contains("phalcon"))
    }

    @Test func clearActionsReloadOnlyARunningBranch() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        await env.stack.set(running: ["8.3"])
        let applies = await env.stack.applyCount
        try await env.manager.clearOPcache(branch: "8.3")
        try await env.manager.clearAPCu(branch: "8.3")
        #expect(await env.stack.fpmReloads == ["8.3", "8.3"])
        #expect(await env.stack.applyCount == applies)
        await #expect(throws: PHPManagerError.notRunning(branch: "8.2")) {
            try await env.manager.clearOPcache(branch: "8.2")
        }
    }
}
