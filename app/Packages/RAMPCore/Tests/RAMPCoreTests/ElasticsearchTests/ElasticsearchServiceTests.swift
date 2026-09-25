import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RAMPCore

// Plan 06-03: on-demand install, ES_PATH_CONF preparation, lifecycle, never-autostart, config-change restart,
// plugin manager (fake runner).

/// Fake `elasticsearch-plugin`: records argv/env, answers `list` from `installed`.
private final class FakePluginRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _envs: [[String: String]] = []
    private var _installed: [String]
    let failInstall: Bool

    init(installed: [String] = [], failInstall: Bool = false) {
        _installed = installed
        self.failInstall = failInstall
    }

    var calls: [[String]] { lock.withLock { _calls } }
    var envs: [[String: String]] { lock.withLock { _envs } }
    /// Sub-commands after the tool path (`list`, `install --batch x`).
    var commands: [[String]] { calls.map { Array($0.dropFirst()) } }

    func run(_ argv: [String], environment: [String: String], timeout: Duration) async -> ProcessRunResult {
        lock.withLock {
            _calls.append(argv)
            _envs.append(environment)
            switch argv.dropFirst().first {
            case "list":
                let text = "warning: ignoring JVM noise\n" + _installed.map { $0 + "\n" }.joined()
                return ProcessRunResult(status: 0, output: text)
            case "install":
                if failInstall { return ProcessRunResult(status: 1, output: "ERROR: Unknown plugin \(argv.last ?? "")") }
                if let name = argv.last { _installed.append(name) }
                return ProcessRunResult(status: 0, output: "-> Installed \(argv.last ?? "")")
            case "remove":
                _installed.removeAll { $0 == argv.last }
                return ProcessRunResult(status: 0, output: "-> removed")
            default:
                return ProcessRunResult(status: 64, output: "?")
            }
        }
    }
}

private func sha512Hex(_ url: URL) throws -> String {
    SHA512.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// Tiny fake ES tarball (`elasticsearch-<v>/…`): bin/elasticsearch, config base files, a relative
/// `jdk.app/…/legal` symlink like the official package. Returns (archive, manifest with a sha512 entry).
private func esFixture(_ fx: FixtureBuilder, version: String = "9.5.4",
                       extra: [String: Any] = [:]) throws -> (URL, Manifest) {
    let fm = FileManager.default
    let work = fx.base.appending(path: "es-src-\(UUID().uuidString)", directoryHint: .isDirectory)
    let top = work.appending(path: "elasticsearch-\(version)", directoryHint: .isDirectory)
    let files: [String: (String, Int)] = [
        "bin/elasticsearch": ("#!/bin/sh\nexec /bin/sleep 30\n", 0o755),
        "bin/elasticsearch-plugin": ("#!/bin/sh\necho plugin\n", 0o755),
        "config/elasticsearch.yml": ("# package yml\n", 0o644),
        "config/jvm.options": ("-XX:+UseG1GC # \(version)\n", 0o644),
        "config/log4j2.properties": ("status = error # \(version)\n", 0o644),
        "config/users": ("", 0o644),
        "config/roles.yml": ("# roles\n", 0o644),
        "jdk.app/Contents/Home/legal/java.base/LICENSE": ("GPL\n", 0o644),
    ]
    for (rel, (content, mode)) in files {
        let url = top.appending(path: rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }
    try fm.createDirectory(at: top.appending(path: "config/jvm.options.d"), withIntermediateDirectories: true)
    let link = top.appending(path: "jdk.app/Contents/Home/legal/java.desktop/LICENSE")
    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "../java.base/LICENSE")

    let archive = fx.dist.appending(path: "elasticsearch-\(version)-darwin-aarch64.tar.gz")
    try FixtureBuilder.run("/usr/bin/tar", ["-czf", archive.path(percentEncoded: false),
                                            "-C", work.path(percentEncoded: false), "elasticsearch-\(version)"])
    try? fm.removeItem(at: work)
    var components = extra
    components["elasticsearch"] = ["9.5": ["version": version, "url": "${RAMP_DIST_BASE}/\(archive.lastPathComponent)",
                                           "sha512": try sha512Hex(archive)]]
    return (archive, try fx.manifest([], extra: components))
}

private func esSleepSpec() -> ServiceSpec {
    ServiceSpec(id: .elasticsearch, executable: URL(filePath: "/bin/sleep"), arguments: ["30"],
                stopTimeout: .seconds(3))
}

private func installedRecord(_ version: String = "9.5.4") -> InstalledPackage {
    InstalledPackage(version: version, sha256: "x", installedAt: .now)
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions]
        as? NSNumber)?.intValue
}

@Suite(.serialized) struct ElasticsearchServiceTests {
    // MARK: Installer

    @Test func installsOfficialStyleTarballWithSha512() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (archive, manifest) = try esFixture(fx)
        let store = ConfigStore(paths: fx.paths)
        let installer = PackageInstaller(paths: fx.paths, configStore: store)

        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let collector = Task { var stages: [InstallProgress.Stage] = []; for await p in stream { stages.append(p.stage) }; return stages }
        let record = try await installer.installElasticsearch(manifest: manifest, progress: continuation)
        let stages = await collector.value

        #expect(record.version == "9.5.4")
        #expect(record.sha256 == (try sha512Hex(archive)))   // digest the manifest publishes
        #expect(stages.first == .downloading)
        #expect(stages.last == .installed(record))
        let current = fx.paths.current(component: "elasticsearch", branch: "9.5")
        #expect(FileManager.default.isExecutableFile(atPath: current.appending(path: "bin/elasticsearch")
            .path(percentEncoded: false)))
        let legal = current.appending(path: "jdk.app/Contents/Home/legal/java.desktop/LICENSE")
        #expect(read(legal) == "GPL\n")   // relative in-package symlink accepted
        #expect(try await store.load().installed["elasticsearch"]?["9.5"] == record)

        // Idempotent: second call returns the same record.
        #expect(try await installer.installElasticsearch(manifest: manifest) == record)
    }

    @Test func sha512MismatchFailsClosed() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (archive, _) = try esFixture(fx)
        let manifest = try fx.manifest([], extra: ["elasticsearch": ["9.5": [
            "version": "9.5.4", "url": "${RAMP_DIST_BASE}/\(archive.lastPathComponent)",
            "sha512": String(repeating: "0", count: 128)]]])
        let store = ConfigStore(paths: fx.paths)
        let error = await #expect(throws: InstallError.self) {
            try await PackageInstaller(paths: fx.paths, configStore: store).installElasticsearch(manifest: manifest)
        }
        guard case .checksumMismatch? = error else { Issue.record("wrong error \(String(describing: error))"); return }
        #expect(try await store.load().installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.paths.root.appending(path: "elasticsearch").path(percentEncoded: false)))
    }

    @Test func defaultSetNeverInstallsElasticsearch() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let redis = try fx.package("redis", version: "8.2.1")
        let (_, withES) = try esFixture(fx)
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.manifestURL)) as! [String: Any]
        var components = raw["components"] as! [String: Any]
        components["redis"] = ["8.2": ["version": "8.2.1", "url": "${RAMP_DIST_BASE}/\(redis.fileName)",
                                       "sha256": redis.sha256, "size": redis.size]]
        raw["components"] = components
        let data = try JSONSerialization.data(withJSONObject: raw)
        let manifest = try Manifest.decode(from: data, manifestURL: fx.manifestURL)
        #expect(withES.entry(component: "elasticsearch", branch: "9.5") != nil)
        #expect(!PackageInstaller.defaultSlots(in: manifest).contains { $0.component == "elasticsearch" })

        let store = ConfigStore(paths: fx.paths)
        let report = await PackageInstaller(paths: fx.paths, configStore: store).installDefaultSet(manifest)
        #expect(report.succeeded)
        #expect(try await store.load().installed["elasticsearch"] == nil)
        #expect(try await store.load().installed["redis"]?["8.2"] != nil)
    }

    // MARK: Elasticvue (installed together with Elasticsearch)

    /// Elasticvue 1.16.0 manifest entry (+ archive) for `esFixture(extra:)`.
    private func elasticvueEntry(_ fx: FixtureBuilder, sha256: String? = nil) throws -> [String: Any] {
        let ev = try fx.package("elasticvue", version: "1.16.0", topLevelDir: "elasticvue-1.16.0")
        return ["1.16": ["version": "1.16.0", "url": "${RAMP_DIST_BASE}/\(ev.fileName)",
                         "sha256": sha256 ?? ev.sha256, "size": ev.size]]
    }

    @Test func installElasticsearchAlsoInstallsElasticvue() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (_, manifest) = try esFixture(fx, extra: ["elasticvue": try elasticvueEntry(fx)])
        let store = ConfigStore(paths: fx.paths)
        let record = try await PackageInstaller(paths: fx.paths, configStore: store).installElasticsearch(manifest: manifest)
        #expect(record.version == "9.5.4")
        let config = try await store.load()
        #expect(config.installed["elasticvue"]?["1.16"]?.version == "1.16.0")
        let index = fx.paths.current(component: "elasticvue", branch: "1.16").appending(path: "index.html")
        #expect(FileManager.default.fileExists(atPath: index.path(percentEncoded: false)))
        // Rendered: default cluster → ES port.
        let files = try ElasticvueConfigGenerator(config: config, paths: fx.paths).files()
        #expect(files.first?.contents.contains("\"uri\":\"http://127.0.0.1:9200\"") == true)
    }

    @Test func elasticvueFailureKeepsElasticsearch() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (_, manifest) = try esFixture(fx, extra: ["elasticvue": try elasticvueEntry(fx, sha256: String(repeating: "0", count: 64))])
        let store = ConfigStore(paths: fx.paths)
        let installer = PackageInstaller(paths: fx.paths, configStore: store)
        let record = try await installer.installElasticsearch(manifest: manifest)
        #expect(try await store.load().installed["elasticsearch"]?["9.5"] == record)
        #expect(try await store.load().installed["elasticvue"] == nil)
        // Explicit install surfaces the error.
        await #expect(throws: InstallError.self) { try await installer.installElasticvue(manifest: manifest) }
    }

    @Test func installElasticvueAloneAndMissingFromManifest() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (_, withoutEV) = try esFixture(fx)
        let store = ConfigStore(paths: fx.paths)
        let installer = PackageInstaller(paths: fx.paths, configStore: store)
        await #expect(throws: InstallError.self) { try await installer.installElasticvue(manifest: withoutEV) }
        #expect(PackageInstaller.elasticvueSlot(in: withoutEV) == nil)
        let (_, withEV) = try esFixture(fx, extra: ["elasticvue": try elasticvueEntry(fx)])
        #expect(PackageInstaller.elasticvueSlot(in: withEV) == PackageKey(component: "elasticvue", branch: "1.16"))
        #expect(!PackageInstaller.defaultSlots(in: withEV).contains { $0.component == "elasticvue" })
        #expect(try await installer.installElasticvue(manifest: withEV).version == "1.16.0")
    }

    @Test func ensureInstalledAddsElasticvueNextToExistingElasticsearch() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        _ = try esFixture(fx, extra: ["elasticvue": try elasticvueEntry(fx)])   // writes dist/manifest.json
        let store = ConfigStore(paths: fx.paths)
        let pkg = InstalledPackage(version: "1", sha256: "x", installedAt: .now)
        let manifestURL = fx.manifestURL
        try await store.update {
            $0.manifestURL = manifestURL
            $0.installed = ["apache": ["2.4": pkg], "redis": ["8.10": pkg],
                            "mysql": [PackageInstaller.defaultMySQLBranch: pkg], "php": ["8.5": pkg]]
        }
        let stack = StackController(paths: fx.paths, configStore: store,
                                    supervisor: ServiceSupervisor(paths: fx.paths, cleanupOrphans: false))
        // No Elasticsearch → nothing to do.
        #expect(try await stack.ensureInstalled()?.succeeded == nil)
        #expect(try await store.load().installed["elasticvue"] == nil)
        // Elasticsearch present, Elasticvue missing → installed on the next launch.
        try await store.update { $0.installed["elasticsearch"] = ["9.5": pkg] }
        let report = try #require(try await stack.ensureInstalled())
        #expect(report.succeeded)
        #expect(try await store.load().installed["elasticvue"]?["1.16"]?.version == "1.16.0")
        #expect(try await stack.ensureInstalled()?.succeeded == nil)
    }

    // MARK: Prepare

    @Test func prepareCopiesBaseFilesByTheRules() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let (_, manifest) = try esFixture(fx)
        let stack = StackController(paths: fx.paths, supervisor: ServiceSupervisor(paths: fx.paths, cleanupOrphans: false))
        try await stack.installer.installElasticsearch(manifest: manifest)
        let es = ElasticsearchService(stack: stack)
        let conf = fx.paths.elasticsearchConfDir
        let fm = FileManager.default

        let changed = try await es.prepare()
        #expect(read(conf.appending(path: "jvm.options")) == "-XX:+UseG1GC # 9.5.4\n")
        #expect(read(conf.appending(path: "log4j2.properties")) == "status = error # 9.5.4\n")
        #expect(read(conf.appending(path: "roles.yml")) == "# roles\n")
        #expect(read(conf.appending(path: "users")) == "")
        #expect(read(conf.appending(path: ElasticsearchService.baseVersionMarker)) == "9.5.4\n")
        // elasticsearch.yml is RAMP's, not the package's.
        #expect(read(fx.paths.elasticsearchConf)?.contains("discovery.type: single-node") == true)
        #expect(read(fx.paths.elasticsearchJvmOptionsDir.appending(path: "ramp.options"))?.contains("-Xms1g") == true)
        #expect(changed.contains(conf.appending(path: "jvm.options").standardizedFileURL))
        #expect(mode(fx.paths.elasticsearchData(branch: "9.5")) == 0o700)
        #expect(mode(fx.paths.elasticsearchTmp) == 0o700)
        #expect(fm.fileExists(atPath: fx.paths.elasticsearchLogs.path(percentEncoded: false)))

        // Local edits survive while the version is unchanged; the keystore is never touched.
        try Data("# mine\n".utf8).write(to: conf.appending(path: "jvm.options"))
        try Data("# my roles\n".utf8).write(to: conf.appending(path: "roles.yml"))
        try Data("KEYSTORE".utf8).write(to: conf.appending(path: "elasticsearch.keystore"))
        let stale = fx.paths.elasticsearchJvmOptionsDir.appending(path: "old.options")
        try Data("-Xmx9g\n".utf8).write(to: stale)
        let second = try await es.prepare()
        #expect(read(conf.appending(path: "jvm.options")) == "# mine\n")
        #expect(!fm.fileExists(atPath: stale.path(percentEncoded: false)))   // pruned
        #expect(second == [stale.standardizedFileURL])

        // Package version change (marker differs) → jvm.options / log4j2 refreshed, other files kept.
        try Data("9.5.3\n".utf8).write(to: conf.appending(path: ElasticsearchService.baseVersionMarker))
        try await es.prepare()
        #expect(read(conf.appending(path: "jvm.options")) == "-XX:+UseG1GC # 9.5.4\n")
        #expect(read(conf.appending(path: "roles.yml")) == "# my roles\n")
        #expect(read(conf.appending(path: "elasticsearch.keystore")) == "KEYSTORE")
        #expect(read(conf.appending(path: ElasticsearchService.baseVersionMarker)) == "9.5.4\n")
    }

    // MARK: Lifecycle

    @Test func startWhenNotInstalledThrows() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let stack = StackController(paths: env.paths, supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false))
        let es = ElasticsearchService(stack: stack, specProvider: { _, _ in esSleepSpec() })
        await #expect(throws: ElasticsearchError.notInstalled(branch: "9.5")) { try await es.start() }
        #expect(await es.state() == .stopped)
    }

    @Test func startStopRestartAndStopAll() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.installed["elasticsearch"] = ["9.5": installedRecord()] }
        let stack = StackController(paths: env.paths, configStore: store,
                                    supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                    specProvider: { _, _ in [] }, renderer: { _, _ in [] })
        let es = ElasticsearchService(stack: stack, specProvider: { _, _ in esSleepSpec() })

        let first = try #require(try await es.start().pid)
        #expect(isAlive(first))
        #expect(FileManager.default.fileExists(atPath: env.paths.elasticsearchConf.path(percentEncoded: false)))
        let second = try #require(try await es.restart().pid)
        #expect(second != first && !isAlive(first))
        await es.stop()
        #expect(await es.state() == .stopped)
        #expect(!isAlive(second))

        // stopAll (app quit / rampctl up exit) includes ES.
        let third = try #require(try await es.start().pid)
        await stack.stopAll()
        #expect(!isAlive(third))
        #expect(await es.state() == .stopped)
    }

    @Test func invalidAutoStopRejectsStart() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update {
            $0.installed["elasticsearch"] = ["9.5": installedRecord()]
            $0.elasticsearch.autoStop = AutoStopSettings(afterHours: 0)
        }
        let stack = StackController(paths: env.paths, configStore: store,
                                    supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false))
        let es = ElasticsearchService(stack: stack, specProvider: { _, _ in esSleepSpec() })
        await #expect(throws: AutoStopError.self) { try await es.start() }
        #expect(await es.state() == .stopped)
    }

    @Test func startAllNeverStartsElasticsearch() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update {
            $0.installed["elasticsearch"] = ["9.5": installedRecord()]
            $0.services["elasticsearch"] = ServiceSettings(autostart: true)   // ignored
        }
        // Default spec provider + renderer: only ES is "installed".
        let stack = StackController(paths: env.paths, configStore: store,
                                    supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false))
        try await stack.prepare()
        let report = try await stack.startAll()
        #expect(report.states[.elasticsearch] == nil)
        #expect(await stack.supervisor.state(of: .elasticsearch) == .stopped)
        #expect(await stack.supervisor.spec(of: .elasticsearch) == nil)
        #expect(!(await stack.expectedServices()).contains(.elasticsearch))
        // A config change with ES never started → still nothing.
        try await store.update { $0.elasticsearch.heap = "2g" }
        let apply = try await stack.applyConfigChanges()
        #expect(apply.changed.contains(env.paths.elasticsearchJvmOptionsDir.appending(path: "ramp.options").standardizedFileURL))
        #expect(apply.started.isEmpty && apply.restarted.isEmpty)
        #expect(await stack.supervisor.state(of: .elasticsearch) == .stopped)
    }

    @Test func configChangeRestartsRunningElasticsearchOnly() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.installed["elasticsearch"] = ["9.5": installedRecord()] }
        let stack = StackController(paths: env.paths, configStore: store,
                                    supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                    specProvider: { _, _ in [] })
        let es = ElasticsearchService(stack: stack, specProvider: { _, _ in esSleepSpec() })
        let before = try #require(try await es.start().pid)

        // Unrelated no-op apply → ES untouched.
        let noop = try await stack.applyConfigChanges()
        #expect(noop.restarted.isEmpty)
        #expect(await es.state().pid == before)

        try await store.update { $0.elasticsearch.heap = "768m" }
        let report = try await stack.applyConfigChanges()
        #expect(report.restarted == [.elasticsearch])
        let after = try #require(await es.state().pid)
        #expect(after != before && !isAlive(before))
        #expect(read(env.paths.elasticsearchJvmOptionsDir.appending(path: "ramp.options"))?.contains("-Xmx768m") == true)

        // Stopped ES + change → not started.
        await es.stop()
        try await store.update { $0.elasticsearch.heap = "1g" }
        let stopped = try await stack.applyConfigChanges()
        #expect(stopped.restarted.isEmpty && stopped.started.isEmpty)
        #expect(await es.state() == .stopped)
    }

    @Test func esConfFilesMapToRestart() {
        let paths = Paths(root: URL(filePath: "/tmp/rt/root"), logs: URL(filePath: "/tmp/rt/logs"))
        let affected = StackController.affectedServices(
            changed: [paths.elasticsearchConf, paths.elasticsearchJvmOptionsDir.appending(path: "ramp.options")], paths: paths)
        #expect(affected.restart == [.elasticsearch])
        #expect(affected.reload.isEmpty)
    }

    @Test func heapValidation() throws {
        #expect(try ElasticsearchService.validateHeap("512M") == "512m")
        #expect(throws: GeneratorError.self) { try ElasticsearchService.validateHeap("100m") }
        #expect(throws: GeneratorError.self) { try ElasticsearchService.validateHeap("1t") }
    }
}

@Suite struct ElasticsearchPluginManagerTests {
    private func makeManager(_ env: TestEnv, runner: FakePluginRunner, plugins: [String] = []) async throws
        -> (ElasticsearchPluginManager, ConfigStore) {
        let store = ConfigStore(paths: env.paths)
        try await store.update {
            $0.installed["elasticsearch"] = ["9.5": installedRecord()]
            $0.elasticsearch.plugins = plugins
        }
        return (ElasticsearchPluginManager(paths: env.paths, configStore: store, runner: runner), store)
    }

    @Test(arguments: ["analysis-icu", "analysis-phonetic", "mapper-size", "a1"])
    func validNames(_ name: String) { #expect(ElasticsearchPluginManager.isValidName(name)) }

    @Test(arguments: ["../x", "a", "-icu", "Analysis-icu", "https://evil/x.zip", "/tmp/p.zip", "file:x", "a b",
                      "analysis_icu", "--verbose", "", String(repeating: "a", count: 65), "icu\n", "anal\u{0131}sis"])
    func invalidNames(_ name: String) { #expect(!ElasticsearchPluginManager.isValidName(name)) }

    @Test func invalidNamesRejectedBeforeRunning() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let runner = FakePluginRunner()
        let (manager, store) = try await makeManager(env, runner: runner)
        await #expect(throws: ElasticsearchError.invalidPluginName("../x")) { try await manager.install("../x") }
        await #expect(throws: ElasticsearchError.invalidPluginName("https://x/p.zip")) { try await manager.remove("https://x/p.zip") }
        #expect(runner.calls.isEmpty)
        #expect(try await store.load().elasticsearch.plugins.isEmpty)
    }

    @Test func installRunsExactArgvAndUpdatesDesiredSet() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let runner = FakePluginRunner()
        let (manager, store) = try await makeManager(env, runner: runner)
        let tool = env.paths.current(component: "elasticsearch", branch: "9.5")
            .appending(path: "bin/elasticsearch-plugin").path(percentEncoded: false)

        let change = try await manager.install("analysis-icu", running: true)
        #expect(change == PluginChange(name: "analysis-icu", changed: true, restartRequired: true))
        #expect(runner.calls == [[tool, "list"], [tool, "install", "--batch", "analysis-icu"]])
        #expect(try await store.load().elasticsearch.plugins == ["analysis-icu"])
        let env0 = try #require(runner.envs.first)
        #expect(env0["ES_PATH_CONF"] == ConfigText.path(env.paths.elasticsearchConfDir))
        #expect(env0["JAVA_HOME"] == nil && env0["ES_JAVA_HOME"] == nil && env0["ES_JAVA_OPTS"] == nil)

        // Already installed → no second install, no restart needed.
        let again = try await manager.install("analysis-icu", running: true)
        #expect(again == PluginChange(name: "analysis-icu", changed: false, restartRequired: false))
        #expect(runner.commands.filter { $0.first == "install" }.count == 1)

        #expect(try await manager.list() == ["analysis-icu"])
        let removed = try await manager.remove("analysis-icu", running: false)
        #expect(removed == PluginChange(name: "analysis-icu", changed: true, restartRequired: false))
        #expect(runner.commands.last == ["remove", "analysis-icu"])
        #expect(try await store.load().elasticsearch.plugins.isEmpty)
    }

    @Test func failedInstallCarriesOutputAndKeepsConfig() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let (manager, store) = try await makeManager(env, runner: FakePluginRunner(failInstall: true))
        let error = await #expect(throws: ElasticsearchError.self) { try await manager.install("no-such-plugin") }
        #expect(error?.localizedDescription.contains("Unknown plugin no-such-plugin") == true)
        #expect(try await store.load().elasticsearch.plugins.isEmpty)
    }

    @Test func reconcileInstallsOnlyMissing() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let runner = FakePluginRunner(installed: ["analysis-icu"])
        let (manager, _) = try await makeManager(env, runner: runner,
                                                 plugins: ["analysis-icu", "analysis-phonetic", "../evil"])
        #expect(try await manager.reconcile() == ["analysis-phonetic"])
        #expect(runner.commands == [["list"], ["install", "--batch", "analysis-phonetic"]])
        #expect(try await manager.reconcile() == [])
    }

    @Test func notInstalledThrows() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let runner = FakePluginRunner()
        let manager = ElasticsearchPluginManager(paths: env.paths, configStore: ConfigStore(paths: env.paths), runner: runner)
        await #expect(throws: ElasticsearchError.notInstalled(branch: "9.5")) { try await manager.list() }
        #expect(runner.calls.isEmpty)
    }

    @Test func parseListIgnoresNoise() {
        let output = "WARNING: A terminally deprecated method\nanalysis-icu\n  mapper-size  \n\n-> done\n"
        #expect(ElasticsearchPluginManager.parseList(output) == ["analysis-icu", "mapper-size"])
    }

    @Test func systemRunnerTimesOut() async throws {
        let env = try TestEnv(); defer { env.cleanup() }
        let runner = SystemProcessRunner(tempDir: env.paths.tmp)
        let started = ContinuousClock.now
        let result = await runner.run(["/bin/sleep", "20"], environment: [:], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(10))
        let ok = await runner.run(["/bin/echo", "hi"], environment: [:], timeout: .seconds(10))
        #expect(ok == ProcessRunResult(status: 0, output: "hi\n"))
    }
}
