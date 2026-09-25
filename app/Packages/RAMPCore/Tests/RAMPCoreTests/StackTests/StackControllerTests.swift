import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// `/bin/sleep` that ignores the reload signals (SIG_IGN survives exec) and dies on SIGTERM.
private func reloadableSpec(_ id: ServiceID, signal: Int32) -> ServiceSpec {
    ServiceSpec(id: id, executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' USR1 USR2; exec /bin/sleep 60"],
                stopTimeout: .seconds(3), reloadSignal: signal)
}

/// Pure fake renderer: httpd.conf content from `apache.port`, php 8.3 ini from a global override,
/// php 8.2 fpm conf constant.
private let fakeRenderer: StackController.Renderer = { config, paths in
    [
        GeneratedFile(path: paths.apacheConf, contents: "Listen \(config.apache.port)\n"),
        GeneratedFile(path: paths.phpIni(branch: "8.3"),
                      contents: "memory_limit=\(config.php.globalIniOverrides["memory_limit"] ?? "128M")\n"),
        GeneratedFile(path: paths.fpmConf(branch: "8.2"), contents: "[global]\n"),
    ]
}

@Suite(.serialized) struct StackControllerTests {
    @Test func affectedServicesMapsFilesToMinimalActions() throws {
        let paths = Paths(root: URL(filePath: "/tmp/rt/root"), logs: URL(filePath: "/tmp/rt/logs"))
        let changed: Set<URL> = [
            paths.apacheVhostsDir.appending(path: "a.local.conf"),
            paths.phpConfD(branch: "8.3").appending(path: "20-apcu.ini"),
            paths.fpmConf(branch: "7.3"),
            paths.mysqlConf(major: "9.7"),
            paths.redisConf,
        ]
        let affected = StackController.affectedServices(changed: changed, paths: paths)
        #expect(affected.reload == [.apache, .phpFPM("8.3"), .phpFPM("7.3")])
        #expect(affected.restart == [.mysql("9.7"), .redis])

        let onlyIni = StackController.affectedServices(changed: [paths.phpIni(branch: "8.4")], paths: paths)
        #expect(onlyIni.reload == [.phpFPM("8.4")])
        #expect(onlyIni.restart.isEmpty)
        #expect(StackController.affectedServices(changed: [paths.configFile], paths: paths).reload.isEmpty)
    }

    @Test func oneFailingServiceDoesNotStopTheOthers() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let specs = [
            sleepSpec("ramp-test-a"),
            ServiceSpec(id: .custom("ramp-test-broken"), executable: URL(filePath: "/nonexistent/httpd")),
            sleepSpec("ramp-test-b"),
        ]
        let controller = StackController(paths: env.paths,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in specs }, renderer: { _, _ in [] })
        try await controller.prepare()
        let report = try await controller.startAll()
        #expect(report.errors.keys.sorted { $0.name < $1.name } == [.custom("ramp-test-broken")])
        #expect(report.states[.custom("ramp-test-a")]?.isRunning == true)
        #expect(report.states[.custom("ramp-test-b")]?.isRunning == true)
        let pids = [report.states[.custom("ramp-test-a")]?.pid, report.states[.custom("ramp-test-b")]?.pid]
        #expect(await controller.orderedStatus().map(\.id.name) == ["ramp-test-a", "ramp-test-broken", "ramp-test-b"])

        await controller.stopAll()
        for pid in pids { #expect(!isAlive(try #require(pid))) }
        // Default site was created by prepare().
        #expect(try String(contentsOf: env.paths.defaultDocroot.appending(path: "index.php"), encoding: .utf8)
                == DefaultSite.indexContents)
    }

    @Test func autostartFalseIsSkipped() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.services["ramp-test-off"] = ServiceSettings(autostart: false) }
        let specs = [sleepSpec("ramp-test-on"), sleepSpec("ramp-test-off")]
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in specs }, renderer: { _, _ in [] })
        let report = try await controller.startAll()
        #expect(report.states[.custom("ramp-test-on")]?.isRunning == true)
        #expect(report.states[.custom("ramp-test-off")] == .stopped)
        await controller.stopAll()
    }

    @Test func applyConfigChangesReloadsOnlyTheAffectedService() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let specs = [
            reloadableSpec(.phpFPM("8.2"), signal: SIGUSR2),
            reloadableSpec(.phpFPM("8.3"), signal: SIGUSR2),
            reloadableSpec(.apache, signal: SIGUSR1),
        ]
        let supervisor = ServiceSupervisor(paths: env.paths, cleanupOrphans: false)
        let controller = StackController(paths: env.paths, configStore: store, supervisor: supervisor,
                                         specProvider: { _, _ in specs }, renderer: fakeRenderer)
        let initial = try await controller.prepare()
        #expect(initial.count == 3)
        let started = try await controller.startAll()
        #expect(started.succeeded)
        // readiness .none: give /bin/sh time to install the SIG_IGN traps before any reload signal.
        try await Task.sleep(for: .milliseconds(300))
        let pidsBefore = await controller.status().mapValues(\.pid)

        // Nothing changed → nothing touched.
        let noop = try await controller.applyConfigChanges()
        #expect(noop.changed.isEmpty && noop.reloaded.isEmpty && noop.restarted.isEmpty)

        // php 8.3 ini only.
        try await store.update { $0.php.globalIniOverrides["memory_limit"] = "512M" }
        let php = try await controller.applyConfigChanges()
        #expect(php.changed == [env.paths.phpIni(branch: "8.3")])
        #expect(php.reloaded == [.phpFPM("8.3")])
        #expect(php.restarted.isEmpty && php.errors.isEmpty)

        // Apache only.
        try await store.update { $0.apache.port = 18081 }
        let apache = try await controller.applyConfigChanges()
        #expect(apache.reloaded == [.apache])

        // Reload never changes PIDs.
        #expect(await controller.status().mapValues(\.pid) == pidsBefore)
        await controller.stopAll()
    }

    @Test func applyConfigChangesPrunesStaleManagedFiles() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let stale = env.paths.apacheVhostsDir.appending(path: "gone.local.conf")
        try FileManager.default.createDirectory(at: env.paths.apacheVhostsDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale)
        let controller = StackController(paths: env.paths,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [] }, renderer: { _, _ in [] })
        let report = try await controller.applyConfigChanges()
        #expect(report.changed == [stale])
        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
    }

    @Test func mysqlBootstrapRefusesNonEmptyUninitializedDatadir() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let config = try await store.update {
            $0.installed["mysql"] = ["9.7": InstalledPackage(version: "9.7.2", sha256: "x", installedAt: .now)]
        }
        let datadir = env.paths.mysqlData(major: "9.7")
        try FileManager.default.createDirectory(at: datadir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: datadir.appending(path: "ibdata1"))
        let boot = MySQLBootstrapper(paths: env.paths, configStore: store)
        await #expect(throws: MySQLBootstrapError.datadirNotEmpty(datadir.path(percentEncoded: false))) {
            try await boot.bootstrapIfNeeded(config: config,
                                             supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                             spec: sleepSpec("ramp-test-mysql"))
        }
        #expect(FileManager.default.fileExists(atPath: datadir.appending(path: "ibdata1").path(percentEncoded: false)))
        #expect(try await store.load().mysql.initialized == false)
    }

    @Test func passwordSQLEscapesLiterals() {
        #expect(MySQLBootstrapper.sqlLiteral("ro'ot\\x") == "'ro''ot\\\\x'")
        let sql = MySQLBootstrapper.passwordSQL("root")
        #expect(sql.contains("ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';"))
        #expect(sql.contains("GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;"))
    }
}

@Suite struct SupervisorProcessGroupTests {
    /// kill -9 of a master must not leave its children behind (php-fpm workers would keep the socket).
    @Test func orphanedChildrenOfACrashedMasterAreKilled() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let childPidFile = env.dir.appending(path: "child.pid")
        let spec = ServiceSpec(id: .custom("ramp-test-master"), executable: URL(filePath: "/bin/sh"),
                               arguments: ["-c", "/bin/sleep 60 & echo $! > '\(childPidFile.path(percentEncoded: false))'; wait"],
                               stopTimeout: .seconds(3))
        let sup = ServiceSupervisor(paths: env.paths, clock: ImmediateClock(), cleanupOrphans: false)
        let master = try #require(await sup.start(spec).pid)
        #expect(await eventually { FileManager.default.fileExists(atPath: childPidFile.path(percentEncoded: false)) })
        try await Task.sleep(for: .milliseconds(50))
        let child = try #require(pid_t(try String(contentsOf: childPidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(isAlive(child))

        kill(master, SIGKILL)
        #expect(await eventually { !isAlive(child) })
        await sup.stopAll()
    }
}
