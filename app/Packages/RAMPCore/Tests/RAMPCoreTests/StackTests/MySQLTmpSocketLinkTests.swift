import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// `/tmp/mysql.sock` compatibility link. Every test uses a link path inside its own temp dir — the real
/// `/tmp/mysql.sock` is never touched.
@Suite struct MySQLTmpSocketLinkTests {
    let run = "/Users/x/Library/Application Support/RAMP/run"
    var target: String { run + "/mysql9.7.sock" }

    // MARK: Decision logic

    @Test func missingPathIsCreated() {
        #expect(MySQLTmpSocketLink.ensureAction(existing: .missing, target: target, runDir: run) == .create)
    }

    @Test func ownLinkWithSameTargetIsKept() {
        #expect(MySQLTmpSocketLink.ensureAction(existing: .symlink(destination: target), target: target, runDir: run)
            == .keep)
        #expect(MySQLTmpSocketLink.ensureAction(existing: .symlink(destination: run + "/./mysql9.7.sock"),
                                                target: target, runDir: run) == .keep)
    }

    @Test func ownLinkToOtherBranchIsReplaced() {
        let old = run + "/mysql8.4.sock"
        #expect(MySQLTmpSocketLink.ensureAction(existing: .symlink(destination: old), target: target, runDir: run)
            == .replace(old: old))
    }

    @Test func foreignSymlinkIsLeftAlone() {
        for dest in ["/Applications/MAMP/tmp/mysql/mysql.sock", run + "-other/mysql9.7.sock", run,
                     run + "/../run-evil/mysql.sock"] {
            let action = MySQLTmpSocketLink.ensureAction(existing: .symlink(destination: dest), target: target, runDir: run)
            #expect(action == .leaveForeign("symlink → \(dest)"), "\(dest)")
            #expect(!MySQLTmpSocketLink.shouldRemove(existing: .symlink(destination: dest), runDir: run), "\(dest)")
        }
    }

    @Test func realSocketOrFileIsLeftAlone() {
        for kind in ["socket", "file", "directory"] {
            #expect(MySQLTmpSocketLink.ensureAction(existing: .other(kind: kind), target: target, runDir: run)
                == .leaveForeign(kind))
            #expect(!MySQLTmpSocketLink.shouldRemove(existing: .other(kind: kind), runDir: run))
        }
    }

    @Test func onlyOwnLinkIsRemoved() {
        #expect(MySQLTmpSocketLink.shouldRemove(existing: .symlink(destination: run + "/mysql8.4.sock"), runDir: run))
        #expect(!MySQLTmpSocketLink.shouldRemove(existing: .missing, runDir: run))
    }

    @Test func standardPathHonorsEnvironment() {
        #expect(MySQLTmpSocketLink.standardPath(environment: [:]) == MySQLTmpSocketLink.defaultPath)
        #expect(MySQLTmpSocketLink.standardPath(environment: [MySQLTmpSocketLink.environmentKey: ""]) == nil)
        #expect(MySQLTmpSocketLink.standardPath(environment: [MySQLTmpSocketLink.environmentKey: "/x/m.sock"])?
            .path(percentEncoded: false) == "/x/m.sock")
    }

    @Test func configDefaultsToEnabledAndDecodesOptionalKey() throws {
        #expect(RampConfig().mysql.tmpSocketSymlink)
        let off = try RampConfig.decode(from: Data(#"{"schemaVersion":1,"mysql":{"tmpSocketSymlink":false}}"#.utf8))
        #expect(!off.mysql.tmpSocketSymlink)
        #expect(off.schemaVersion == 1)
        let roundTrip = try RampConfig.decode(from: off.encoded())
        #expect(!roundTrip.mysql.tmpSocketSymlink)
    }

    // MARK: Filesystem (temp dir)

    @Test func filesystemCreateReplaceKeepRemove() throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let linkURL = env.dir.appending(path: "tmp/mysql.sock", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let link = MySQLTmpSocketLink(linkPath: linkURL, paths: env.paths)
        let t97 = env.paths.mysqlSocket(major: "9.7"), t84 = env.paths.mysqlSocket(major: "8.4")
        let p = { (u: URL) in u.path(percentEncoded: false) }

        #expect(link.inspect() == .missing)
        #expect(link.removeIfOwned() == .absent)
        #expect(link.ensure(target: t84) == .created(target: p(t84)))
        #expect(link.inspect() == .symlink(destination: p(t84)))
        #expect(link.ensure(target: t84) == .unchanged)
        #expect(link.ensure(target: t97) == .replaced(old: p(t84), new: p(t97)))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: p(linkURL)) == p(t97))
        #expect(link.describe(expectedTarget: t97).contains("(RAMP)"))
        #expect(link.describe(expectedTarget: t97).contains("dangling"))
        #expect(link.removeIfOwned() == .removed(old: p(t97)))
        #expect(link.inspect() == .missing)
        // No leftover temp links from the atomic swap.
        #expect(try FileManager.default.contentsOfDirectory(atPath: p(linkURL.deletingLastPathComponent())).isEmpty)
    }

    @Test func filesystemNeverTouchesForeignFiles() throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let linkURL = env.dir.appending(path: "tmp/mysql.sock", directoryHint: .notDirectory)
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = linkURL.path(percentEncoded: false)
        let link = MySQLTmpSocketLink(linkPath: linkURL, paths: env.paths)
        let target = env.paths.mysqlSocket(major: "9.7")

        // Regular file.
        try Data("x".utf8).write(to: linkURL)
        #expect(link.inspect() == .other(kind: "file"))
        #expect(link.ensure(target: target).warning != nil)
        #expect(link.removeIfOwned().warning != nil)
        #expect(try String(contentsOf: linkURL, encoding: .utf8) == "x")
        try fm.removeItem(at: linkURL)

        // Symlink elsewhere (e.g. MAMP).
        try fm.createSymbolicLink(atPath: path, withDestinationPath: "/Applications/MAMP/tmp/mysql/mysql.sock")
        if case .skippedForeign = link.ensure(target: target) {} else { Issue.record("foreign symlink replaced") }
        if case .skippedForeign = link.removeIfOwned() {} else { Issue.record("foreign symlink removed") }
        #expect(try fm.destinationOfSymbolicLink(atPath: path) == "/Applications/MAMP/tmp/mysql/mysql.sock")
        #expect(link.describe(expectedTarget: nil).contains("not RAMP's"))
        try fm.removeItem(at: linkURL)

        // Real unix socket (another MySQL).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        #expect(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(link.inspect() == .other(kind: "socket"))
        #expect(link.ensure(target: target) == .skippedForeign("\(path): socket"))
        #expect(link.removeIfOwned() == .skippedForeign("\(path): socket"))
        #expect(link.inspect() == .other(kind: "socket"))
    }
}

// MARK: - StackController integration (serialized suite)

private func fakeMySQL(_ major: String) -> ServiceSpec {
    ServiceSpec(id: .mysql(major), executable: URL(filePath: "/bin/sleep"), arguments: ["30"],
                stopTimeout: .seconds(3))
}

extension StackControllerTests {
    @Test func tmpSocketLinkFollowsMySQLLifecycle() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let linkURL = env.dir.appending(path: "tmp/mysql.sock", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = linkURL.path(percentEncoded: false)
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.mysql.branch = "9.7" }
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { config, _ in [fakeMySQL(config.mysql.branch)] },
                                         renderer: { _, _ in [] }, mysqlTmpSocketLink: linkURL)
        let fm = FileManager.default
        let dest = { try fm.destinationOfSymbolicLink(atPath: path) }

        _ = try await controller.startAll()
        #expect(try dest() == env.paths.mysqlSocket(major: "9.7").path(percentEncoded: false))

        // Branch change → own link replaced.
        try await store.update { $0.mysql.branch = "8.4" }
        _ = try await controller.applyConfigChanges()
        #expect(try dest() == env.paths.mysqlSocket(major: "8.4").path(percentEncoded: false))

        // Single-service stop removes it, start recreates it.
        await controller.stop(.mysql("8.4"))
        #expect(!fm.fileExists(atPath: path) && (try? dest()) == nil)
        _ = await controller.start(.mysql("8.4"))
        #expect(try dest() == env.paths.mysqlSocket(major: "8.4").path(percentEncoded: false))

        // Setting off → removed while MySQL keeps running.
        try await store.update { $0.mysql.tmpSocketSymlink = false }
        _ = try await controller.applyConfigChanges()
        #expect((try? dest()) == nil)
        #expect(await controller.status()[.mysql("8.4")]?.isRunning == true)
        try await store.update { $0.mysql.tmpSocketSymlink = true }
        _ = try await controller.applyConfigChanges()
        #expect((try? dest()) != nil)

        await controller.stopAll()
        #expect((try? dest()) == nil)
    }

    @Test func tmpSocketLinkLeavesForeignSocketAlone() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let linkURL = env.dir.appending(path: "tmp/mysql.sock", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = linkURL.path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/opt/homebrew/var/mysql.sock")
        let controller = StackController(paths: env.paths,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [fakeMySQL("9.7")] },
                                         renderer: { _, _ in [] }, mysqlTmpSocketLink: linkURL)
        _ = try await controller.startAll()
        if case .skippedForeign = await controller.syncMySQLTmpSocketLink() {} else { Issue.record("expected skip") }
        #expect(env.log("mysql9.7").contains("left alone"))
        await controller.stopAll()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == "/opt/homebrew/var/mysql.sock")
    }

    @Test func tmpSocketLinkUnmanagedByDefault() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let controller = StackController(paths: env.paths,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [] }, renderer: { _, _ in [] })
        #expect(controller.tmpSocketLink == nil)
        #expect(await controller.syncMySQLTmpSocketLink() == nil)
    }
}
