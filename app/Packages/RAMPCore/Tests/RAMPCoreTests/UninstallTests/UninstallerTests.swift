import Foundation
import Synchronization
import Testing
@testable import RAMPCore

/// Records calls; never touches the system.
final class FakeUninstallActions: UninstallActions, Sendable {
    let calls = Mutex<[String]>([])
    let failDump: Bool
    let failHosts: Bool
    let busy: Bool

    init(failDump: Bool = false, failHosts: Bool = false, busy: Bool = false) {
        self.failDump = failDump
        self.failHosts = failHosts
        self.busy = busy
    }

    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    private func log(_ s: String) { calls.withLock { $0.append(s) } }
    var recorded: [String] { calls.withLock { $0 } }

    func acquireLock() async throws -> @Sendable () async -> Void {
        if busy { throw UninstallError.busy("update") }
        log("lock")
        return { [self] in log("unlock") }
    }
    func stopServices() async { log("stop") }
    func dumpAllDatabases(to url: URL) async throws {
        log("dump")
        if failDump { throw Boom() }
        try Data("-- MySQL dump\n-- Dump completed on 2026-09-25\n".utf8).write(to: url)
    }
    func removeHostsBlock() async throws {
        log("hosts")
        if failHosts { throw Boom() }
    }
    func unregisterHelper() async throws { log("helper") }
    func unregisterLoginItem() async throws { log("login") }
    func removePreferencesDomain(_ bundleID: String) async { log("prefs:\(bundleID)") }
    func moveToTrash(_ url: URL) async throws { log("trash") }
}

@Suite struct UninstallerTests {
    /// Fake install: data, logs, caches, prefs, a vhost docroot outside and a symlink to it inside the root.
    private func makeInstall() throws -> (UninstallSandbox, UninstallContext, URL) {
        let s = try UninstallSandbox()
        let fm = FileManager.default
        try fm.createDirectory(at: s.appSupport.appending(path: "mysql-data/9.7"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100_000).write(to: s.appSupport.appending(path: "mysql-data/9.7/ibdata1"))
        try Data("{}".utf8).write(to: s.appSupport.appending(path: "ramp.json"))
        try Data("log".utf8).write(to: s.logs.appending(path: "apache-error.log"))
        try Data("c".utf8).write(to: s.caches.appending(path: "cache.db"))
        let link = s.appSupport.appending(path: "www/project", directoryHint: .notDirectory)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: s.docroot)
        var config = RampConfig()
        config.vhosts = [Vhost(domain: "shop.local", docroot: s.docroot.path(percentEncoded: false))]
        config.installed["mysql"] = ["9.7": InstalledPackage(version: "9.7.2", sha256: "x", installedAt: Date())]
        config.mysql.initialized = true
        let ctx = UninstallContext(paths: s.paths, home: s.home, library: s.library, config: config,
                                   appBundle: nil, now: Date(timeIntervalSince1970: 1_790_000_000))
        return (s, ctx, link)
    }

    private func options(_ s: UninstallSandbox, dump: Bool = true) -> UninstallOptions {
        UninstallOptions(dumpDatabases: dump, dumpDirectory: s.home.appending(path: "Desktop"))
    }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0
    }

    private func assertNothingDeleted(_ s: UninstallSandbox) {
        #expect(exists(s.appSupport.appending(path: "mysql-data/9.7/ibdata1")))
        #expect(exists(s.logs.appending(path: "apache-error.log")))
        #expect(exists(s.caches.appending(path: "cache.db")))
        #expect(exists(s.prefs))
        #expect(exists(s.docroot.appending(path: "index.php")))
    }

    @Test func dryRunListsGuardedPathsSizesAndKeptProjects() throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        let plan = UninstallPlanner(context: ctx).plan(options: options(s))
        #expect(plan.isExecutable)
        let paths = plan.deletions.map { $0.url.path(percentEncoded: false) }
        let appSupport = UninstallPathGuard.canonical(s.appSupport.path(percentEncoded: false))
        #expect(paths.contains(appSupport + "/mysql-data"))
        #expect(paths.contains(appSupport))
        #expect(paths.contains { $0.hasSuffix("Preferences/sk.tyron.ramp.plist") })
        #expect(paths.contains { $0.hasSuffix("Caches/sk.tyron.ramp") })
        #expect(!paths.contains { $0.contains("/Sites") })
        #expect(plan.deletions.first { $0.url.lastPathComponent == "mysql-data" }!.bytes >= 100_000)
        #expect(plan.keptDocroots == [s.docroot.path(percentEncoded: false)])
        #expect(plan.dumpFile?.lastPathComponent.hasPrefix("RAMP-backup-") == true)
        #expect(plan.steps.first?.kind == .acquireLock)
        #expect(!plan.steps.contains { if case .trashApp = $0.kind { true } else { false } })
        #expect(plan.render().contains("keep \(s.docroot.path(percentEncoded: false))"))
        // Dump strictly before the first deletion.
        let dumpIndex = plan.steps.firstIndex { if case .dumpDatabases = $0.kind { true } else { false } }!
        let firstDelete = plan.steps.firstIndex { if case .delete = $0.kind { true } else { false } }!
        #expect(dumpIndex < firstDelete)
    }

    @Test func executeRemovesRampDataButNotProjectsOrSymlinkTargets() async throws {
        let (s, ctx, link) = try makeInstall()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        let plan = planner.plan(options: options(s))
        let actions = FakeUninstallActions()
        let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard).execute(plan)
        #expect(report.aborted == nil)
        #expect(report.warnings.isEmpty)
        #expect(!exists(s.appSupport))
        #expect(!exists(s.logs))
        #expect(!exists(s.caches))
        #expect(!exists(s.prefs))
        #expect(!exists(link))
        // Project folder and the symlink's target are untouched.
        #expect(exists(s.docroot.appending(path: "index.php")))
        #expect(exists(s.home.appending(path: "Desktop")))
        #expect(exists(s.library.appending(path: "Preferences")))
        #expect(exists(s.library.appending(path: "Application Support")))
        #expect(report.dumpFile.map { exists($0) } == true)
        #expect(actions.recorded == ["lock", "stop", "dump", "hosts", "helper", "login",
                                     "prefs:sk.tyron.ramp", "unlock"])
    }

    @Test func dumpFailureDeletesNothing() async throws {
        let (s, ctx, link) = try makeInstall()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        let actions = FakeUninstallActions(failDump: true)
        let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard)
            .execute(planner.plan(options: options(s)))
        #expect(report.aborted?.contains("backup failed") == true)
        #expect(report.deleted.isEmpty)
        assertNothingDeleted(s)
        #expect(exists(link))
        #expect(!actions.recorded.contains("hosts"))
        #expect(actions.recorded.last == "unlock")
    }

    @Test func lockBusyDoesNothing() async throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        let actions = FakeUninstallActions(busy: true)
        let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard)
            .execute(planner.plan(options: options(s)))
        #expect(report.aborted != nil)
        #expect(actions.recorded.isEmpty)
        assertNothingDeleted(s)
    }

    @Test func refusedRampHomeMakesPlanNotExecutable() async throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        var bad = ctx
        bad.paths = Paths(root: s.sites, logs: s.logs)   // RAMP_HOME = ~/Sites
        let planner = UninstallPlanner(context: bad)
        let plan = planner.plan(options: options(s))
        #expect(!plan.isExecutable)
        #expect(plan.deletions.allSatisfy { !$0.url.path(percentEncoded: false).contains("/Sites") })
        let actions = FakeUninstallActions()
        let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard).execute(plan)
        #expect(report.aborted != nil)
        #expect(actions.recorded.isEmpty)
        assertNothingDeleted(s)
    }

    @Test func tamperedPlanWithProjectPathIsRejectedBeforeAnything() async throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        var plan = planner.plan(options: options(s))
        plan.steps.insert(UninstallStep(id: 99, kind: .delete(s.docroot, bytes: 0), description: "evil"), at: 3)
        let actions = FakeUninstallActions()
        let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard).execute(plan)
        #expect(report.aborted != nil)
        #expect(actions.recorded.isEmpty)
        assertNothingDeleted(s)
    }

    @Test func hostsFailureIsReportedButDoesNotBlockDeletion() async throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        let report = await Uninstaller(actions: FakeUninstallActions(failHosts: true), pathGuard: planner.pathGuard)
            .execute(planner.plan(options: options(s, dump: false)))
        #expect(report.aborted == nil)
        #expect(report.manualSteps.contains(Uninstaller.manualHostsCleanup))
        #expect(!exists(s.appSupport))
        #expect(exists(s.docroot.appending(path: "index.php")))
    }

    @Test func dumpDirectoryInsideRampRootIsRefused() throws {
        let (s, ctx, _) = try makeInstall()
        defer { s.cleanup() }
        let plan = UninstallPlanner(context: ctx).plan(
            options: UninstallOptions(dumpDatabases: true, dumpDirectory: s.appSupport.appending(path: "backups")))
        #expect(!plan.isExecutable)
    }
}
