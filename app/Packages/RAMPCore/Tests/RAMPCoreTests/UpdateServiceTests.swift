import Foundation
import Synchronization
import Testing
@testable import RAMPCore

// MARK: - Fakes

/// Ordered record of what the fakes were asked to do.
private actor CallLog {
    private(set) var calls: [String] = []
    func add(_ s: String) { calls.append(s) }
}

private actor FakeStack: UpdateStackControlling {
    let log: CallLog
    var states: [ServiceID: ServiceState]
    /// Versions whose start "fails" (the service never becomes ready), read from the `current` link.
    let failingStartVersions: Set<String>
    let paths: Paths

    init(log: CallLog, paths: Paths, states: [ServiceID: ServiceState] = [:], failingStartVersions: Set<String> = []) {
        self.log = log
        self.paths = paths
        self.states = states
        self.failingStartVersions = failingStartVersions
    }

    func serviceState(_ id: ServiceID) async -> ServiceState { states[id] ?? .stopped }

    func stopService(_ id: ServiceID) async {
        await log.add("stop \(id.name)")
        states[id] = .stopped
    }

    func startService(_ id: ServiceID) async -> ServiceState {
        await log.add("start \(id.name)")
        let component: String
        switch id {
        case .redis: component = "redis"
        case .mysql: component = "mysql"
        case .apache: component = "apache"
        default: component = "php"
        }
        let branchDir = paths.root.appending(path: component)
        let branches = (try? FileManager.default.contentsOfDirectory(atPath: branchDir.path(percentEncoded: false))) ?? []
        let active = branches.compactMap {
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: paths.current(component: component, branch: $0).path(percentEncoded: false))
        }.map { ($0 as NSString).lastPathComponent }
        if active.contains(where: failingStartVersions.contains) {
            states[id] = .backingOff(attempt: 1, until: .now)
            return .backingOff(attempt: 1, until: .now)
        }
        states[id] = .running(pid: 4242, since: .now)
        return states[id]!
    }

    func renderConfigs() async throws { await log.add("render") }
}

/// Fails for the versions listed (whatever `current` of the checked branch points at).
private struct FakeProbe: HealthProbing {
    let paths: Paths
    let failing: Set<String>
    let log: CallLog

    func check(component: String, branch: String, config: RampConfig, serviceRunning: Bool) async -> HealthResult {
        let target = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: paths.current(component: component, branch: branch).path(percentEncoded: false))) ?? "?"
        let version = (target as NSString).lastPathComponent
        await log.add("probe \(component) \(version) running=\(serviceRunning)")
        return failing.contains(version) ? .fail("probe says \(version) is broken") : .pass("ok \(version)")
    }
}

private struct FakeDumper: MySQLDumping {
    let log: CallLog
    let fail: Bool

    func automaticDump(config: RampConfig) async throws -> DumpResult {
        await log.add("dump")
        if fail { throw DumpError.failed(status: 2, output: "Access denied") }
        return DumpResult(file: URL(filePath: "/tmp/fake.sql"), bytes: 10)
    }
}

// MARK: - Tests

@Suite struct UpdateServiceTests {
    private let fm = FileManager.default

    private struct Env {
        let fx: FixtureBuilder
        let store: ConfigStore
        let installer: PackageInstaller
        let log: CallLog
        let stack: FakeStack
        let lock: MaintenanceLock
        let service: UpdateService
    }

    private func makeEnv(_ fx: FixtureBuilder, states: [ServiceID: ServiceState] = [:],
                         failingStart: Set<String> = [], failingProbe: Set<String> = [],
                         dumpFails: Bool = false) -> Env {
        let store = ConfigStore(paths: fx.paths)
        let installer = PackageInstaller(paths: fx.paths, configStore: store)
        let log = CallLog()
        let stack = FakeStack(log: log, paths: fx.paths, states: states, failingStartVersions: failingStart)
        let lock = MaintenanceLock()
        let service = UpdateService(installer: installer, stack: stack, store: store, lock: lock,
                                    dumper: FakeDumper(log: log, fail: dumpFails),
                                    probe: FakeProbe(paths: fx.paths, failing: failingProbe, log: log))
        return Env(fx: fx, store: store, installer: installer, log: log, stack: stack, lock: lock, service: service)
    }

    private func link(_ fx: FixtureBuilder, _ component: String, _ branch: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: fx.paths.current(component: component, branch: branch)
            .path(percentEncoded: false))
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Installs `component branch old` and returns the manifest offering `new`.
    private func installThenOffer(_ env: Env, _ component: String, _ branch: String, old: String, new: String,
                                  newSHAOverride: String? = nil) async throws -> Manifest {
        let a = try env.fx.package(component, version: old, topLevelDir: old)
        let m1 = try env.fx.manifest([.init(component: component, branch: branch, version: old, archive: a)])
        try await env.installer.install(component: component, branch: branch, from: m1)
        let b = try env.fx.package(component, version: new, topLevelDir: new)
        return try env.fx.manifest([.init(component: component, branch: branch, version: new, archive: b,
                                          sha256Override: newSHAOverride)])
    }

    private func item(_ env: Env, _ manifest: Manifest) async throws -> UpdateItem {
        let plan = UpdatePolicy.plan(manifest: manifest, config: try await env.store.load())
        return try #require(plan.items.first)
    }

    // MARK: Success / rollback

    @Test func successFlipsRecordsPreviousAndRestartsOnlyAffectedService() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now), .apache: .running(pid: 2, since: .now)])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")
        let steps = StepLog()

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest) { steps.add($0) }

        #expect(outcome == .updated(from: "8.10.2", to: "8.10.3"))
        #expect(link(fx, "redis", "8.10") == "../8.10.3")
        let record = try #require(try await env.store.load().installed["redis"]?["8.10"])
        #expect(record.version == "8.10.3")
        #expect(record.previousVersion == "8.10.2")
        #expect(await env.log.calls == ["stop redis", "render", "start redis", "probe redis 8.10.3 running=true"])
        #expect(exists(fx.paths.package(component: "redis", version: "8.10.2")))   // previous kept
        let seen = steps.all
        #expect(seen.first == .downloading)
        #expect(seen.contains(.restarting) && seen.contains(.checking))
        #expect(seen.last == .finished(outcome))
    }

    @Test func probeFailureRollsBackToPrevious() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now)], failingProbe: ["8.10.3"])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")
        let before = try #require(try await env.store.load().installed["redis"]?["8.10"])

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)

        guard case .rolledBack(let to, let reason) = outcome else {
            Issue.record("expected rollback, got \(outcome)"); return
        }
        #expect(to == "8.10.2")
        #expect(reason.contains("broken"))
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
        #expect(try await env.store.load().installed["redis"]?["8.10"] == before)
        #expect(exists(fx.paths.package(component: "redis", version: "8.10.3")))   // kept for diagnosis
        #expect(await env.log.calls == [
            "stop redis", "render", "start redis", "probe redis 8.10.3 running=true",
            "stop redis", "render", "start redis", "probe redis 8.10.2 running=true",
        ])
    }

    @Test func serviceThatNeverBecomesReadyRollsBack() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now)], failingStart: ["8.10.3"])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)

        guard case .rolledBack(to: "8.10.2", _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
        #expect(await env.stack.serviceState(.redis).isRunning)
    }

    @Test func checksumMismatchChangesNothingAndNeverStops() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now)])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3",
                                                  newSHAOverride: String(repeating: "a", count: 64))
        let before = try await env.store.load()

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)

        guard case .failed(.prepareFailed(let message)) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(message.contains("checksum"))
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
        #expect(try await env.store.load() == before)
        #expect(await env.log.calls.isEmpty)
        #expect(!exists(fx.paths.package(component: "redis", version: "8.10.3")))
    }

    @Test func busyLockFailsFast() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now)])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")
        let token = try await env.lock.acquire(.mampImport)

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)
        #expect(outcome == .failed(.busy(.mampImport)))
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
        #expect(await env.log.calls.isEmpty)

        await env.lock.release(token)
        #expect(await env.service.apply(try await item(env, manifest), manifest: manifest)
            == .updated(from: "8.10.2", to: "8.10.3"))
        #expect(await env.lock.current == nil)
    }

    @Test func stoppedServiceIsNotStartedOnlyOfflineChecks() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx)
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)
        #expect(outcome == .updated(from: "8.10.2", to: "8.10.3"))
        #expect(await env.log.calls == ["render", "probe redis 8.10.3 running=false"])
    }

    // MARK: MySQL

    @Test func mysqlPatchDumpsBeforeAnythingElse() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.mysql("9.7"): .running(pid: 1, since: .now)])
        let manifest = try await installThenOffer(env, "mysql", "9.7", old: "9.7.2", new: "9.7.3")
        let item = try await item(env, manifest)
        #expect(item.requiresDumpFirst)

        let outcome = await env.service.apply(item, manifest: manifest)
        #expect(outcome == .updated(from: "9.7.2", to: "9.7.3"))
        let calls = await env.log.calls
        #expect(calls == ["dump", "stop mysql9.7", "render", "start mysql9.7", "probe mysql 9.7.3 running=true"])
    }

    @Test func mysqlDumpFailureAbortsBeforeDownload() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.mysql("9.7"): .running(pid: 1, since: .now)], dumpFails: true)
        let manifest = try await installThenOffer(env, "mysql", "9.7", old: "9.7.2", new: "9.7.3")

        let outcome = await env.service.apply(try await item(env, manifest), manifest: manifest)
        guard case .failed(.dumpFailed(let message)) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(message.contains("Access denied"))
        #expect(await env.log.calls == ["dump"])
        #expect(link(fx, "mysql", "9.7") == "../9.7.2")
        #expect(!exists(fx.paths.package(component: "mysql", version: "9.7.3")))
    }

    @Test func migrationIsNeverApplied() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx)
        let item = UpdateItem(component: "mysql", branch: "10.0", from: "9.7.2", to: "10.0.1", kind: .migration,
                              requiresDumpFirst: true)
        #expect(await env.service.apply(item, manifest: try fx.manifest([]))
            == .failed(.migrationNotSupportedHere(component: "mysql", branch: "10.0")))
        #expect(await env.log.calls.isEmpty)
    }

    // MARK: Retention, new branch, automatic, manual rollback

    @Test func retentionKeepsCurrentAndPrevious() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx)
        let m2 = try await installThenOffer(env, "php", "8.3", old: "8.3.34", new: "8.3.35")
        #expect(await env.service.apply(try await item(env, m2), manifest: m2) == .updated(from: "8.3.34", to: "8.3.35"))
        let c = try fx.package("php", version: "8.3.36", topLevelDir: "8.3.36")
        let m3 = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.36", archive: c)])
        #expect(await env.service.apply(try await item(env, m3), manifest: m3) == .updated(from: "8.3.35", to: "8.3.36"))

        let dirs = try await env.installer.versionsOnDisk(component: "php")
        #expect(dirs == ["8.3", "8.3.35", "8.3.36"])
        let record = try await env.store.load().installed["php"]?["8.3"]
        #expect(record?.version == "8.3.36")
        #expect(record?.previousVersion == "8.3.35")
    }

    @Test func newPHPBranchInstallsDisabled() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx)
        let a = try fx.package("php", version: "8.4.26", topLevelDir: "8.4.26")
        let b = try fx.package("php", version: "8.5.11", topLevelDir: "8.5.11")
        let m1 = try fx.manifest([.init(component: "php", branch: "8.4", version: "8.4.26", archive: a)])
        try await env.installer.install(component: "php", branch: "8.4", from: m1)
        let m2 = try fx.manifest([.init(component: "php", branch: "8.4", version: "8.4.26", archive: a),
                                  .init(component: "php", branch: "8.5", version: "8.5.11", archive: b)])
        let item = try await item(env, m2)
        #expect(item.kind == .newBranch)

        #expect(await env.service.apply(item, manifest: m2) == .updated(from: nil, to: "8.5.11"))
        let config = try await env.store.load()
        #expect(config.installed["php"]?["8.5"]?.version == "8.5.11")
        #expect(config.php.branches["8.5"]?.enabled == false)
        #expect(await env.log.calls == ["render"])
    }

    @Test func applyAutomaticAppliesOnlyAutomaticItems() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx)
        let p1 = try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35")
        let r1 = try fx.package("redis", version: "8.10.2", topLevelDir: "8.10.2")
        let m1 = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: p1),
                                  .init(component: "redis", branch: "8.10", version: "8.10.2", archive: r1)])
        try await env.installer.install(component: "php", branch: "8.3", from: m1)
        try await env.installer.install(component: "redis", branch: "8.10", from: m1)
        let p2 = try fx.package("php", version: "8.3.36", topLevelDir: "8.3.36")
        let r2 = try fx.package("redis", version: "8.10.3", topLevelDir: "8.10.3")
        let m2 = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.36", archive: p2),
                                  .init(component: "redis", branch: "8.10", version: "8.10.3", archive: r2)])
        let plan = UpdatePolicy.plan(manifest: m2, config: try await env.store.load())

        let results = await env.service.applyAutomatic(plan, manifest: m2)
        #expect(results.map(\.0.component) == ["php"])
        #expect(results.first?.1 == .updated(from: "8.3.35", to: "8.3.36"))
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
    }

    @Test func manualRollbackSwapsCurrentAndPrevious() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let env = makeEnv(fx, states: [.redis: .running(pid: 1, since: .now)])
        let manifest = try await installThenOffer(env, "redis", "8.10", old: "8.10.2", new: "8.10.3")
        _ = await env.service.apply(try await item(env, manifest), manifest: manifest)

        #expect(await env.service.rollbackToPrevious(component: "redis", branch: "8.10")
            == .updated(from: "8.10.3", to: "8.10.2"))
        #expect(link(fx, "redis", "8.10") == "../8.10.2")
        let record = try await env.store.load().installed["redis"]?["8.10"]
        #expect(record?.version == "8.10.2")
        #expect(record?.previousVersion == "8.10.3")
    }

    @Test func affectedServiceMapping() {
        var config = RampConfig()
        let now = Date()
        config.installed = ["apache": ["2.4": .init(version: "2.4.68", sha256: "x", installedAt: now)],
                            "redis": ["8.10": .init(version: "8.10.2", sha256: "x", installedAt: now)]]
        config.php.branches["7.3"] = PHPBranchSettings(enabled: false)
        #expect(UpdateService.affectedService(component: "php", branch: "8.3", config: config) == .phpFPM("8.3"))
        #expect(UpdateService.affectedService(component: "php", branch: "7.3", config: config) == nil)
        #expect(UpdateService.affectedService(component: "apache", branch: "2.4", config: config) == .apache)
        #expect(UpdateService.affectedService(component: "mysql", branch: "9.7", config: config) == .mysql("9.7"))
        #expect(UpdateService.affectedService(component: "mysql", branch: "8.4", config: config) == nil)
        #expect(UpdateService.affectedService(component: "phpmyadmin", branch: "5.2", config: config) == nil)
        #expect(UpdateService.affectedService(component: "redis", branch: "8.10", config: config) == .redis)
    }
}

/// Thread-safe progress collector for the `@Sendable` progress callback.
private final class StepLog: Sendable {
    private let steps = Mutex<[UpdateProgress]>([])
    func add(_ p: UpdateProgress) { steps.withLock { $0.append(p) } }
    var all: [UpdateProgress] { steps.withLock { $0 } }
}

// MARK: - MaintenanceLock

@Suite struct MaintenanceLockTests {
    @Test func secondAcquireIsBusyUntilReleased() async throws {
        let lock = MaintenanceLock()
        let token = try await lock.acquire(.update)
        await #expect(throws: MaintenanceError.busy(.update)) { try await lock.acquire(.uninstall) }
        #expect(await lock.current == .update)
        await lock.release(token)
        let again = try await lock.acquire(.uninstall)
        #expect(again.reason == .uninstall)
    }

    @Test func fileLockExcludesOtherInstances() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ramp-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "maintenance.lock")
        let a = MaintenanceLock(lockFile: file)
        let b = MaintenanceLock(lockFile: file)
        let token = try await a.acquire(.dump)
        await #expect(throws: MaintenanceError.busy(nil)) { try await b.acquire(.update) }
        await a.release(token)
        _ = try await b.acquire(.update)
    }

    @Test func withLockReleasesOnError() async throws {
        struct Boom: Error {}
        let lock = MaintenanceLock()
        await #expect(throws: Boom.self) { try await lock.withLock(.update) { throw Boom() } }
        #expect(await lock.current == nil)
    }
}

// MARK: - MySQLDumper

private final class FakeStreamRunner: StreamingProcessRunning {
    let body: String
    let status: Int32
    let seen = Mutex<[(argv: [String], env: [String: String])]>([])

    init(body: String, status: Int32) {
        self.body = body
        self.status = status
    }

    func run(_ argv: [String], environment: [String: String], stdout: URL, timeout: Duration) async -> ProcessRunResult {
        seen.withLock { $0.append((argv, environment)) }
        try? Data(body.utf8).write(to: stdout)
        return ProcessRunResult(status: status, output: status == 0 ? "" : "mysqldump: Got error: 1045")
    }
}

@Suite struct MySQLDumperTests {
    private let fm = FileManager.default

    private func paths() -> Paths {
        let base = FileManager.default.temporaryDirectory.appending(path: "ramp-dump-\(UUID().uuidString)")
        return Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
    }

    @Test func successfulDumpIsVerifiedPrivateAndPasswordNotInArgv() async throws {
        let p = paths(); defer { try? fm.removeItem(at: p.root.deletingLastPathComponent()) }
        let runner = FakeStreamRunner(body: "-- MySQL dump\nCREATE TABLE t (a int);\n-- Dump completed on 2026-09-25 12:00:00\n",
                                      status: 0)
        let dumper = MySQLDumper(paths: p, runner: runner)
        let url = p.backups.appending(path: "x.sql")

        let result = try await dumper.dumpAll(to: url, socket: p.mysqlSocket(major: "9.7"), user: "root",
                                              password: "s3cr3t!", branch: "9.7")

        #expect(result.file == url)
        #expect(result.bytes > 0)
        let mode = try fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let call = try #require(runner.seen.withLock { $0.first })
        #expect(!call.argv.joined(separator: " ").contains("s3cr3t!"))
        #expect(call.env["MYSQL_PWD"] == "s3cr3t!")
        #expect(call.argv[1] == "--no-defaults")
        for option in ["--all-databases", "--routines", "--events", "--triggers", "--single-transaction",
                       "--hex-blob", "--set-gtid-purged=OFF", "--default-character-set=utf8mb4"] {
            #expect(call.argv.contains(option))
        }
        #expect(call.argv[0].hasSuffix("mysql/9.7/current/bin/mysqldump"))
    }

    @Test func missingTrailerIsIncompleteAndDeleted() async throws {
        let p = paths(); defer { try? fm.removeItem(at: p.root.deletingLastPathComponent()) }
        let dumper = MySQLDumper(paths: p, runner: FakeStreamRunner(body: "-- MySQL dump\nINSERT", status: 0))
        let url = p.backups.appending(path: "x.sql")
        await #expect(throws: DumpError.incomplete(url.path(percentEncoded: false))) {
            try await dumper.dumpAll(to: url, socket: p.mysqlSocket(major: "9.7"), user: "root", password: "r",
                                     branch: "9.7")
        }
        #expect(!fm.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func nonZeroExitFailsAndDeletesPartial() async throws {
        let p = paths(); defer { try? fm.removeItem(at: p.root.deletingLastPathComponent()) }
        let dumper = MySQLDumper(paths: p, runner: FakeStreamRunner(body: "partial", status: 2))
        let url = p.backups.appending(path: "x.sql")
        do {
            _ = try await dumper.dumpAll(to: url, socket: p.mysqlSocket(major: "9.7"), user: "root", password: "r",
                                         branch: "9.7")
            Issue.record("expected failure")
        } catch let DumpError.failed(status, output) {
            #expect(status == 2)
            #expect(output.contains("1045"))
        }
        #expect(!fm.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func automaticDumpRequiresRunningMySQL() async throws {
        let p = paths(); defer { try? fm.removeItem(at: p.root.deletingLastPathComponent()) }
        var config = RampConfig()
        config.installed["mysql"] = ["9.7": .init(version: "9.7.2", sha256: "x", installedAt: Date())]
        let dumper = MySQLDumper(paths: p, runner: FakeStreamRunner(body: "", status: 0))
        await #expect(throws: DumpError.notRunning("9.7")) { try await dumper.automaticDump(config: config) }
    }

    @Test func pruneKeepsNewestThreeAutomaticDumps() throws {
        let p = paths(); defer { try? fm.removeItem(at: p.root.deletingLastPathComponent()) }
        try fm.createDirectory(at: p.backups, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var names: [String] = []
        for i in 0..<5 {
            let url = MySQLDumper.automaticDumpURL(paths: p, branch: "9.7", date: base.addingTimeInterval(Double(i) * 60))
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: base.addingTimeInterval(Double(i) * 60)],
                                 ofItemAtPath: url.path(percentEncoded: false))
            names.append(url.lastPathComponent)
        }
        try Data("manual".utf8).write(to: p.backups.appending(path: "manual.sql"))

        let removed = MySQLDumper.pruneAutomaticDumps(in: p.backups, keep: 3)
        #expect(Set(removed.map(\.lastPathComponent)) == Set(names.prefix(2)))
        let left = try fm.contentsOfDirectory(atPath: p.backups.path(percentEncoded: false)).sorted()
        #expect(left == (Array(names.suffix(3)) + ["manual.sql"]).sorted())
        #expect(names[0].hasPrefix("mysql-9.7-") && names[0].hasSuffix(".sql"))
    }
}

// MARK: - PackageInstaller prepare / activate / switch / prune

@Suite struct PackageInstallerSplitTests {
    private let fm = FileManager.default

    @Test func prepareDoesNotTouchCurrentOrConfig() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let store = ConfigStore(paths: fx.paths)
        let installer = PackageInstaller(paths: fx.paths, configStore: store)
        let a = try fx.package("redis", version: "8.10.2", topLevelDir: "8.10.2")
        let m = try fx.manifest([.init(component: "redis", branch: "8.10", version: "8.10.2", archive: a)])

        let prepared = try await installer.prepare(component: "redis", branch: "8.10", from: m)
        #expect(!prepared.alreadyInstalled)
        #expect(fm.fileExists(atPath: prepared.directory.appending(path: "bin/redis-server").path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(atPath: fx.paths.current(component: "redis", branch: "8.10")
            .path(percentEncoded: false))) == nil)
        #expect(try await store.load().installed.isEmpty)

        let record = try await installer.activate(prepared)
        #expect(record.version == "8.10.2")
        #expect(record.previousVersion == nil)
        #expect(try fm.destinationOfSymbolicLink(atPath: fx.paths.current(component: "redis", branch: "8.10")
            .path(percentEncoded: false)) == "../8.10.2")
        // Re-prepare of the recorded version → alreadyInstalled, nothing downloaded again.
        #expect(try await installer.prepare(component: "redis", branch: "8.10", from: m).alreadyInstalled)
    }

    @Test func switchCurrentRequiresSaneExistingDir() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let installer = PackageInstaller(paths: fx.paths, configStore: ConfigStore(paths: fx.paths))
        let a = try fx.package("redis", version: "8.10.2", topLevelDir: "8.10.2")
        let m = try fx.manifest([.init(component: "redis", branch: "8.10", version: "8.10.2", archive: a)])
        try await installer.install(component: "redis", branch: "8.10", from: m)

        await #expect(throws: InstallError.self) {
            try await installer.switchCurrent(component: "redis", branch: "8.10", toVersion: "8.10.1")
        }
        await #expect(throws: InstallError.self) {
            try await installer.switchCurrent(component: "redis", branch: "8.10", toVersion: "../../etc")
        }
        // A dir without the sanity file is refused.
        try fm.createDirectory(at: fx.paths.package(component: "redis", version: "8.10.9"), withIntermediateDirectories: true)
        await #expect(throws: InstallError.self) {
            try await installer.switchCurrent(component: "redis", branch: "8.10", toVersion: "8.10.9")
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: fx.paths.current(component: "redis", branch: "8.10")
            .path(percentEncoded: false)) == "../8.10.2")
    }

    @Test func pruneNeverRemovesOtherBranchesOrLinkedVersions() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let installer = PackageInstaller(paths: fx.paths, configStore: ConfigStore(paths: fx.paths))
        for v in ["8.3.33", "8.3.34", "8.3.35", "8.4.26"] {
            try fm.createDirectory(at: fx.paths.package(component: "php", version: v), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: fx.paths.branchDir(component: "php", branch: "8.3"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: fx.paths.current(component: "php", branch: "8.3").path(percentEncoded: false),
                                  withDestinationPath: "../8.3.33")   // odd state: current on an old version

        let removed = try await installer.prune(component: "php", branch: "8.3", current: "8.3.35", previous: "8.3.34")
        #expect(removed.isEmpty)   // 8.3.33 is linked by `current` → kept
        let removed2 = try await installer.prune(component: "php", branch: "8.4", current: "8.4.27", previous: nil)
        #expect(removed2 == ["8.4.26"])
        #expect(try await installer.versionsOnDisk(component: "php") == ["8.3", "8.3.33", "8.3.34", "8.3.35"])
    }
}
