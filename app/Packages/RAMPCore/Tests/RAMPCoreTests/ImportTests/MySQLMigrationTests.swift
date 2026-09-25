import Darwin
import Foundation
import Synchronization
import Testing
@testable import RAMPCore

// Plan 07-04: pure logic of the MAMP MySQL migration engine + the state machine with fake steps.
// Nothing here touches a real MAMP datadir — only temp dirs.

private func tempDir(_ name: String = "mig") throws -> URL {
    let url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        .appending(path: "ramp-\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Minimal fake 8.0 datadir.
private func fakeDatadir(in dir: URL) throws -> URL {
    let src = dir.appending(path: "src80", directoryHint: .isDirectory)
    for (rel, text) in [
        ("mysql.ibd", String(repeating: "m", count: 4096)), ("ibdata1", "ib"), ("undo_001", "u"), ("auto.cnf", "uuid"),
        ("binlog.000001", String(repeating: "b", count: 1000)), ("binlog.000002", "bb"), ("binlog.index", "./binlog.000001"),
        ("mysqld-auto.cnf", "{}"), ("ibtmp1", "t"), ("mysql_error.log", "log"), (".DS_Store", "ds"),
        ("#innodb_temp/temp_1.ibt", "tt"), ("#innodb_redo/#ib_redo1", "r"), ("app_one/customers.ibd", "c"),
        ("app@002dtwo/items.ibd", "i"), ("mysql/general_log.CSM", "g"), ("sys/sys_config.ibd", "s"),
        ("app_one/.DS_Store", "x"),
    ] {
        try write(src.appending(path: rel), text)
    }
    try FileManager.default.createDirectory(at: src.appending(path: "empty_db"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: src.appending(path: "outside").path(percentEncoded: false),
                                               withDestinationPath: "/etc/hosts")
    try FileManager.default.createSymbolicLink(atPath: src.appending(path: "inside.link").path(percentEncoded: false),
                                               withDestinationPath: "auto.cnf")
    return src
}

@Suite struct DatadirExclusionTests {
    @Test func classification() {
        let c = DatadirExclusion.classify
        #expect(c("binlog.000001", false) == .binlog)
        #expect(c("binlog.index", false) == .binlog)
        #expect(c("mysql-bin.000123", false) == .binlog)
        #expect(c("binlog.1", false) == .copy)                 // not a binlog sequence
        #expect(c("app_one/binlog.000001", false) == .copy)    // only top level
        #expect(c("mysql_error.log", false) == .log)
        #expect(c("app_one/x.log", false) == .log)
        #expect(c(".DS_Store", false) == .excluded)
        #expect(c("app_one/.DS_Store", false) == .excluded)
        #expect(c("mysqld-auto.cnf", false) == .excluded)
        #expect(c("ibtmp1", false) == .excluded)
        #expect(c("mysqld.pid", false) == .excluded)
        #expect(c("#innodb_temp", true) == .excluded)
        #expect(c("#innodb_redo", true) == .copy)
        #expect(c("mysql.ibd", false) == .copy)
        #expect(c("auto.cnf", false) == .copy)
        #expect(c("server-key.pem", false) == .copy)
        #expect(c("app@002dtwo/items.ibd", false) == .copy)
    }

    @Test func filenameDecoding() {
        #expect(MySQLFilename.decode("app@002dtwo") == "app-two")
        #expect(MySQLFilename.decode("europe@002dstate_local") == "europe-state_local")
        #expect(MySQLFilename.decode("plain") == "plain")
        #expect(MySQLFilename.decode("odd@0G") == "odd@0G")
    }

    @Test func precheckMath() {
        let gb: Int64 = 1_073_741_824
        #expect(PrecheckMath.requiredBytes(toCopy: 40 * gb, clonePossible: true) == 5 * gb)
        #expect(PrecheckMath.requiredBytes(toCopy: 40 * gb, clonePossible: false) == 49 * gb)
        #expect(PrecheckMath.requiredBytes(toCopy: 0, clonePossible: false) == 5 * gb)
    }
}

@Suite struct DatadirCopierTests {
    @Test func scanSizesSchemasAndSymlinks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try DatadirCopier().scan(try fakeDatadir(in: dir))
        #expect(scan.sizes.binlogBytes == 1000 + 2 + 15)
        #expect(scan.sizes.logBytes == 3)
        #expect(scan.schemaDirectories == ["app@002dtwo", "app_one", "empty_db"])
        #expect(scan.internalSymlinks == ["inside.link": "auto.cnf"])
        #expect(scan.warnings.contains { $0.contains("outside") })
        #expect(!scan.files.contains { $0.relativePath.hasPrefix("#innodb_temp") })
        #expect(scan.sizes.toCopyFiles == scan.files.filter { $0.category == .copy }.count)
        #expect(scan.sizes.totalBytes == scan.sizes.toCopyBytes + scan.sizes.binlogBytes + scan.sizes.logBytes
                + scan.sizes.excludedBytes)
    }

    @Test func copyExcludesResumesAndLeavesSourceUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try fakeDatadir(in: dir)
        let dst = dir.appending(path: "copy", directoryHint: .isDirectory)
        let copier = DatadirCopier()
        let scan = try copier.scan(src)
        let before = SourceFingerprint.of(scan)

        // Interrupted after 3 files …
        #expect(throws: DatadirCopyError.simulatedInterruption(3)) {
            try copier.copy(scan, from: src, to: dst, interruptAfter: 3)
        }
        // … resume skips them.
        let report = try copier.copy(scan, from: src, to: dst)
        #expect(report.filesSkipped == 3)
        #expect(report.filesCopied == scan.sizes.toCopyFiles - 3)

        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: dst.appending(path: rel).path(percentEncoded: false)) }
        #expect(exists("mysql.ibd") && exists("app@002dtwo/items.ibd") && exists("#innodb_redo/#ib_redo1") && exists("empty_db"))
        for excluded in ["binlog.000001", "binlog.index", "mysqld-auto.cnf", "ibtmp1", "mysql_error.log", ".DS_Store",
                         "#innodb_temp", "app_one/.DS_Store", "outside"] {
            #expect(!exists(excluded), "\(excluded) must not be copied")
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: dst.appending(path: "inside.link").path(percentEncoded: false)) == "auto.cnf")
        let fileMode = try fm.attributesOfItem(atPath: dst.appending(path: "mysql.ibd").path(percentEncoded: false))[.posixPermissions] as? Int
        let dirMode = try fm.attributesOfItem(atPath: dst.appending(path: "app_one").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(fileMode == 0o600 && dirMode == 0o700)

        let after = SourceFingerprint.of(try copier.scan(src))
        #expect(before.matches(after))
        // Third run: everything skipped.
        #expect(try copier.copy(scan, from: src, to: dst).filesCopied == 0)
    }

    @Test func destinationInsideSourceRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try fakeDatadir(in: dir)
        let scan = try DatadirCopier().scan(src)
        #expect(throws: DatadirCopyError.destinationInsideSource) {
            try DatadirCopier().copy(scan, from: src, to: src.appending(path: "copy"))
        }
    }

    @Test func fingerprintDetectsChange() {
        let a = SourceFingerprint(mysqlIbdSize: 10, mysqlIbdMtime: 1_790_000_000.123456, entryCount: 5)
        #expect(a.matches(a))
        #expect(!a.matches(SourceFingerprint(mysqlIbdSize: 11, mysqlIbdMtime: a.mysqlIbdMtime, entryCount: 5)))
        #expect(!a.matches(SourceFingerprint(mysqlIbdSize: 10, mysqlIbdMtime: a.mysqlIbdMtime + 0.5, entryCount: 5)))
        #expect(!a.matches(SourceFingerprint(mysqlIbdSize: 10, mysqlIbdMtime: a.mysqlIbdMtime, entryCount: 6)))
    }
}

@Suite struct ErrorLogScannerTests {
    // Lines captured from the synthetic 8.0.40 → 8.4.11 → 9.7.2 run (07-04).
    static let log84 = """
    2026-09-24T22:24:01.599636Z 0 [System] [MY-015015] [Server] MySQL Server - start.
    2026-09-24T22:24:01.734431Z 0 [Warning] [MY-010159] [Server] Setting lower_case_table_names=2 because file system for /tmp/x/ is case insensitive
    2026-09-24T22:24:01.781970Z 1 [System] [MY-011090] [Server] Data dictionary upgrading from version '80023' to '80300'.
    2026-09-24T22:24:01.882972Z 1 [System] [MY-013413] [Server] Data dictionary upgrade from version '80023' to '80300' completed.
    2026-09-24T22:24:02.211223Z 4 [System] [MY-013381] [Server] Server upgrade from '80040' to '80411' started.
    2026-09-24T22:24:03.224036Z 4 [System] [MY-013381] [Server] Server upgrade from '80040' to '80411' completed.
    2026-09-24T22:24:03.297228Z 0 [Warning] [MY-010068] [Server] CA certificate ca.pem is self signed.
    2026-09-24T22:24:03.301060Z 0 [System] [MY-010931] [Server] /x/8.4.11/bin/mysqld: ready for connections. Version: '8.4.11'  socket: '/tmp/m84.sock'  port: 0  MySQL Community Server - GPL.
    """
    static let log97 = """
    2026-09-24T22:24:12.435213Z 0 [Warning] [MY-010312] [Server] The plugin 'mysql_native_password' used to authenticate user 'legacy'@'localhost' is not loaded. Nobody can currently login using this account.
    2026-09-24T22:24:12.436520Z 0 [System] [MY-010931] [Server] /x/9.7.2/bin/mysqld: ready for connections. Version: '9.7.2'  socket: '/tmp/m97.sock'  port: 0  MySQL Community Server - GPL.
    2026-09-24T22:24:20.908304Z 0 [System] [MY-010910] [Server] /x/9.7.2/bin/mysqld: Shutdown complete (mysqld 9.7.2)  MySQL Community Server - GPL.
    """

    @Test func upgradeMarkers() {
        let events = ErrorLogScanner.scan(Self.log84)
        #expect(events == [
            .dictionaryUpgradeStarted(from: "80023", to: "80300"),
            .dictionaryUpgradeCompleted(from: "80023", to: "80300"),
            .serverUpgradeStarted(from: "80040", to: "80411"),
            .serverUpgradeCompleted(from: "80040", to: "80411"),
            .ready(version: "8.4.11"),
        ])
        #expect(ErrorLogScanner.failures(events).isEmpty)
    }

    @Test func unloadedPluginReadyShutdown() {
        #expect(ErrorLogScanner.scan(Self.log97) == [
            .unloadedAuthPlugin(user: "legacy", host: "localhost", plugin: "mysql_native_password"),
            .ready(version: "9.7.2"),
            .shutdownComplete,
        ])
    }

    @Test func errors() {
        let lc = "2026-09-24T22:00:00Z 1 [ERROR] [MY-011087] [Server] Different lower_case_table_names settings for server ('0') and data dictionary ('2')."
        let engine = "2026-09-24T22:00:00Z 1 [ERROR] [MY-010727] [Server] Unknown/unsupported storage engine: TokuDB"
        let aborting = "2026-09-24T22:00:00Z 0 [ERROR] [MY-010119] [Server] Aborting"
        let generic = "2026-09-24T22:00:00Z 1 [ERROR] [MY-012592] [InnoDB] Operating system error number 2 in a file operation."
        #expect(ErrorLogScanner.classify(lc) == .lowerCaseMismatch("Different lower_case_table_names settings for server ('0') and data dictionary ('2')."))
        #expect(ErrorLogScanner.classify(engine) == .fatal("Unknown/unsupported storage engine: TokuDB"))
        #expect(ErrorLogScanner.classify(aborting) == .fatal("Aborting"))
        #expect(ErrorLogScanner.classify(generic) == .error("Operating system error number 2 in a file operation."))
        #expect(ErrorLogScanner.failures(ErrorLogScanner.scan([lc, generic].joined(separator: "\n"))).count == 2)
        #expect(ErrorLogScanner.classify("2026 0 [Warning] [MY-010068] [Server] CA certificate ca.pem is self signed.") == nil)
    }

    @Test func upgradeServerArguments() {
        let u = URL(filePath: "/r")
        let a84 = MySQLUpgradeRunner.arguments(branch: "8.4", basedir: u, datadir: u, socket: u, pidFile: u, errorLog: u, tmpdir: u)
        let a97 = MySQLUpgradeRunner.arguments(branch: "9.7", basedir: u, datadir: u, socket: u, pidFile: u, errorLog: u, tmpdir: u)
        #expect(a84.first == "--no-defaults")
        for flag in ["--skip-networking", "--skip-log-bin", "--upgrade=AUTO", "--innodb-fast-shutdown=0", "--mysqlx=OFF"] {
            #expect(a84.contains(flag) && a97.contains(flag))
        }
        #expect(a84.contains("--mysql-native-password=ON"))
        #expect(!a97.contains("--mysql-native-password=ON"))
        #expect(!a84.contains { $0.hasPrefix("--lower-case-table-names") })   // platform default, like MAMP
    }

    @Test func generatedMyCnfEnablesNativePasswordOnlyFor84() throws {
        var config = RampConfig()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        config.installed["mysql"] = ["8.4": InstalledPackage(version: "8.4.11", sha256: "0", installedAt: date),
                                     "9.7": InstalledPackage(version: "9.7.2", sha256: "0", installedAt: date)]
        let paths = Paths(root: URL(filePath: "/tmp/r"), logs: URL(filePath: "/tmp/l"))
        config.mysql.branch = "8.4"
        #expect(try MySQLConfigGenerator(config: config, paths: paths).render().contains("\nmysql-native-password=ON\n"))
        #expect(!(try MySQLConfigGenerator(config: config, paths: paths).render().contains("lower_case_table_names")))
        config.mysql.branch = "9.7"
        #expect(!(try MySQLConfigGenerator(config: config, paths: paths).render().contains("mysql-native-password")))
    }
}

@Suite struct DefinerFilterTests {
    @Test func rewritesDefiners() {
        #expect(DefinerFilter.rewrite("/*!50013 DEFINER=`app_owner`@`localhost` SQL SECURITY DEFINER */")
                == "/*!50013 DEFINER=CURRENT_USER SQL SECURITY DEFINER */")
        #expect(DefinerFilter.rewrite("/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`%`*/ /*!50003 TRIGGER t AFTER INSERT")
                == "/*!50003 CREATE*/ /*!50017 DEFINER=CURRENT_USER*/ /*!50003 TRIGGER t AFTER INSERT")
        #expect(DefinerFilter.rewrite("CREATE DEFINER=`we``ird`@`h` PROCEDURE `p`()") == "CREATE DEFINER=CURRENT_USER PROCEDURE `p`()")
        #expect(DefinerFilter.rewrite("/*!50106 CREATE*/ /*!50117 DEFINER=`a`@`b`*/ /*!50106 EVENT e") == "/*!50106 CREATE*/ /*!50117 DEFINER=CURRENT_USER*/ /*!50106 EVENT e")
        #expect(DefinerFilter.rewrite("DEFINER=CURRENT_USER") == "DEFINER=CURRENT_USER")
        #expect(DefinerFilter.rewrite("no definer here") == "no definer here")
    }

    @Test func streamFilterAcrossChunksKeepsInserts() {
        let dump = "-- header\n/*!50013 DEFINER=`u`@`localhost` SQL SECURITY DEFINER */\n"
            + "INSERT INTO t VALUES ('DEFINER=`keep`@`me`');\nCREATE DEFINER=`u`@`h` PROCEDURE p() BEGIN END\nlast"
        let bytes = Array(dump.utf8)
        for chunkSize in [1, 3, 7, 64, bytes.count] {
            var filter = DefinerStreamFilter()
            var out = Data()
            var i = 0
            while i < bytes.count {
                out.append(filter.feed(Data(bytes[i..<min(i + chunkSize, bytes.count)])))
                i += chunkSize
            }
            out.append(filter.finish())
            #expect(String(decoding: out, as: UTF8.self) == "-- header\n/*!50013 DEFINER=CURRENT_USER SQL SECURITY DEFINER */\n"
                    + "INSERT INTO t VALUES ('DEFINER=`keep`@`me`');\nCREATE DEFINER=CURRENT_USER PROCEDURE p() BEGIN END\nlast",
                    "chunk \(chunkSize)")
        }
    }

    @Test func dumpAndImportArguments() {
        let d = LogicalDBMigrator.dumpArguments(database: "app-two")
        for flag in ["--single-transaction", "--routines", "--triggers", "--events", "--hex-blob", "--set-gtid-purged=OFF",
                     "--no-tablespaces", "--column-statistics=0", "--default-character-set=utf8mb4"] {
            #expect(d.contains(flag))
        }
        #expect(d.suffix(2) == ["--", "app-two"])
        let i = LogicalDBMigrator.importArguments(database: "x")
        #expect(i.contains("--init-command=SET SESSION sql_mode='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'"))
        #expect(i.contains("--max-allowed-packet=1G"))
        #expect(!(d + i).contains { $0.contains("password") })
    }
}

@Suite struct AccountAuthPlannerTests {
    static let accounts = [
        MySQLAccount(user: "root", host: "localhost", plugin: "mysql_native_password"),
        MySQLAccount(user: "legacy", host: "localhost", plugin: "mysql_native_password"),
        MySQLAccount(user: "app", host: "%", plugin: "caching_sha2_password"),
    ]

    @Test func defaultsConvertRootOnly() throws {
        let plan = try AccountAuthPlanner.plan(accounts: Self.accounts, requests: [], rootPassword: "pw", targetBranch: "9.7")
        #expect(plan.conversions == [AccountConversion(account: Self.accounts[0], plugin: .cachingSHA2, password: "pw")])
        #expect(plan.unconverted == [Self.accounts[1]])
        #expect(plan.keptNative.isEmpty)
    }

    @Test func perAccountTargets() throws {
        let plan = try AccountAuthPlanner.plan(
            accounts: Self.accounts,
            requests: [AccountAuthRequest(user: "legacy", host: "localhost", plugin: .sha256, password: "l"),
                       AccountAuthRequest(user: "app", host: "%", plugin: .sha256, password: "a")],
            rootPassword: "pw", rootPlugin: .sha256, targetBranch: "9.7")
        #expect(plan.conversions.map { "\($0.account.key)=\($0.plugin.rawValue)" }
                == ["legacy@localhost=sha256_password", "app@%=sha256_password", "root@localhost=sha256_password"])
        #expect(plan.unconverted.isEmpty)
        let sql = AccountAuthPlanner.sql(plan, rootPassword: "p'w", rootPlugin: .sha256)
        #expect(sql.contains("ALTER USER 'legacy'@'localhost' IDENTIFIED WITH sha256_password BY 'l';"))
        #expect(sql.contains("CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH sha256_password BY 'p''w';"))
        #expect(sql.hasSuffix("FLUSH PRIVILEGES;\n"))
    }

    @Test func errorsAndNativeOn84() throws {
        #expect(throws: AccountAuthPlanError.passwordRequired("'legacy'@'localhost'")) {
            try AccountAuthPlanner.plan(accounts: Self.accounts,
                                        requests: [AccountAuthRequest(user: "legacy", host: "localhost", plugin: .sha256)],
                                        rootPassword: "pw", targetBranch: "9.7")
        }
        #expect(throws: AccountAuthPlanError.nativeRequires84("'legacy'@'localhost'")) {
            try AccountAuthPlanner.plan(accounts: Self.accounts,
                                        requests: [AccountAuthRequest(user: "legacy", host: "localhost", plugin: .native)],
                                        rootPassword: "pw", targetBranch: "9.7")
        }
        #expect(throws: AccountAuthPlanError.unknownAccount("'ghost'@'x'")) {
            try AccountAuthPlanner.plan(accounts: Self.accounts,
                                        requests: [AccountAuthRequest(user: "ghost", host: "x", plugin: .sha256, password: "g")],
                                        rootPassword: "pw", targetBranch: "9.7")
        }
        let plan = try AccountAuthPlanner.plan(accounts: Self.accounts, requests: [], rootPassword: "pw", targetBranch: "8.4")
        #expect(plan.keptNative == [Self.accounts[1]])
        #expect(plan.unconverted.isEmpty)
    }

    @Test func parseRequests() {
        #expect(AccountAuthRequest.parse("legacy@localhost=sha256") == AccountAuthRequest(user: "legacy", host: "localhost", plugin: .sha256))
        #expect(AccountAuthRequest.parse("a@b@%=caching_sha2_password") == AccountAuthRequest(user: "a@b", host: "%", plugin: .cachingSHA2))
        #expect(AccountAuthRequest.parse("nohost=sha256") == nil)
        #expect(AccountAuthRequest.parse("u@h=bogus") == nil)
    }

    @Test func batchParsing() {
        #expect(MySQLClient.parseBatch("a\tb\\tc\nx\\\\y\t\\n\n") == [["a", "b\tc"], ["x\\y", "\n"]])
    }
}

@Suite struct SourceUsageProbeTests {
    @Test func psMatchingNamesOnlyTheDatadir() {
        let ps = """
          101 /Applications/MAMP/Library/bin/mysql80/bin/mysqld --defaults-file=/x/my.cnf --datadir=/Library/Application Support/appsolute/MAMP PRO/db/mysql80 --port=3306
          102 /bin/sh /Applications/MAMP/Library/bin/mysql80/bin/mysqld_safe --datadir=/tmp/ramp-mig/src80
          103 /Applications/MAMP/Library/bin/mysql80/bin/mysqld --no-defaults --datadir=/private/tmp/ramp-mig/src80 --socket=/tmp/s.sock
          104 /usr/bin/vim /tmp/ramp-mig/src80
        """
        #expect(SourceUsageProbe.matching(psOutput: ps, datadir: URL(filePath: "/tmp/ramp-mig/src80")).map(\.0) == [103])
        #expect(SourceUsageProbe.matching(psOutput: ps, datadir: SourceUsageProbe.mampDatadir).map(\.0) == [101])
        #expect(SourceUsageProbe.defaultSockets(for: SourceUsageProbe.mampDatadir) == [SourceUsageProbe.mampSocket])
        #expect(SourceUsageProbe.defaultSockets(for: URL(filePath: "/tmp/x")).isEmpty)
    }

    @Test func ibdataLockHeldByAnotherProcess() async throws {
        let dir = try tempDir("lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ibdata = dir.appending(path: "ibdata1")
        try write(ibdata, "x")
        #expect(SourceUsageProbe.lockHolder(ibdata.path(percentEncoded: false)) == nil)
        let holder = try LockHolder(ibdata)
        defer { holder.stop() }
        let usage = SourceUsageProbe.check(datadir: dir, sockets: [])
        #expect(usage.inUse)
        #expect(usage.reasons.first?.contains("ibdata1 is locked by process \(holder.pid)") == true)
    }
}

/// Child process holding an fcntl write lock (a lock of our own process would be invisible to F_GETLK).
private final class LockHolder: Sendable {
    let process: Process
    let pid: Int32

    init(_ file: URL) throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(60)",
                       file.path(percentEncoded: false)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        _ = out.fileHandleForReading.availableData   // wait for "locked"
        process = p
        pid = p.processIdentifier
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

// MARK: - State machine with fake steps

private actor FakeSteps: MySQLMigrationSteps {
    var calls: [String] = []
    var failOnce: String?
    var cancelDuring: String?

    init(failOnce: String? = nil) { self.failOnce = failOnce }

    private func record(_ name: String, _ ctx: MigrationContext) throws {
        calls.append(name)
        if failOnce == name {
            failOnce = nil
            throw MigrationError.verifyFailed("injected failure in \(name)")
        }
    }

    func copy(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        try record("copy", ctx)
        var s = state
        s.copiedFiles = 3
        return s
    }
    func upgrade(branch: String, _ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        try record("upgrade\(branch)", ctx)
        var s = state
        s.serverVersions[branch] = branch == "8.4" ? "8.4.11" : "9.7.2"
        return s
    }
    func convertUsers(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        try record("users", ctx)
        return state
    }
    func verify(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        try record("verify", ctx)
        return state
    }
    func activate(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        try record("activate", ctx)
        return state
    }
    func importDatabases(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        calls.append("import")
        var s = state
        for db in ["a", "b", "c"] where !s.doneDatabases.contains(db) {
            if failOnce == db {
                failOnce = nil
                s.inProgressDatabase = db
                try await ctx.save(s)
                throw LogicalMigrationError.importFailed(database: db, output: "boom")
            }
            s.doneDatabases.append(db)
            s.inProgressDatabase = nil
            try await ctx.save(s)
        }
        return s
    }
    func finish(_ state: MigrationState, _ ctx: MigrationContext) async -> MigrationState {
        calls.append("finish")
        return state
    }
}

@Suite struct MySQLMigrationStateTests {
    private func setup() async throws -> (Paths, URL, URL) {
        let dir = try tempDir("state")
        let paths = Paths(root: dir.appending(path: "home"), logs: dir.appending(path: "logs"))
        try paths.ensureDirectories()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await ConfigStore(paths: paths).update {
            $0.installed["mysql"] = ["8.4": InstalledPackage(version: "8.4.11", sha256: "0", installedAt: date),
                                     "9.7": InstalledPackage(version: "9.7.2", sha256: "0", installedAt: date)]
        }
        return (paths, try fakeDatadir(in: dir), dir)
    }

    @Test func transitionTable() {
        var s = MigrationState(method: .datadirUpgrade, sourcePath: "/s", targetBranch: "9.7")
        var seen: [MigrationStep] = []
        while let step = MigrationStep.next(after: s) {
            seen.append(step)
            s.phase = step.resultPhase
        }
        #expect(seen == [.copy, .upgrade84, .convertUsers, .upgrade97, .verify, .activate])
        s = MigrationState(method: .datadirUpgrade, sourcePath: "/s", targetBranch: "8.4")
        seen = []
        while let step = MigrationStep.next(after: s) {
            seen.append(step)
            s.phase = step.resultPhase
        }
        #expect(seen == [.copy, .upgrade84, .convertUsers, .verify, .activate])
        s = MigrationState(method: .logical, sourcePath: "/s", targetBranch: "9.7")
        #expect(MigrationStep.next(after: s) == .importDatabases)
        s.phase = .copying
        s.method = .datadirUpgrade
        #expect(MigrationStep.next(after: s) == .copy)
    }

    @Test func stateRoundTrip() throws {
        var s = MigrationState(method: .logical, sourcePath: "/s", targetBranch: "9.7", now: Date(timeIntervalSince1970: 1_790_000_000))
        s.phase = .importing
        s.failure = MigrationFailure(step: "imported", message: "x", at: Date(timeIntervalSince1970: 1_790_000_001))
        s.doneDatabases = ["a"]
        s.sourceFingerprint = SourceFingerprint(mysqlIbdSize: 1, mysqlIbdMtime: 1_790_000_000.123456, entryCount: 2)
        s.unconvertedAccounts = [MySQLAccount(user: "u", host: "h", plugin: "mysql_native_password")]
        let data = try MySQLMigration.encoder.encode(s)
        let back = try MySQLMigration.decoder.decode(MigrationState.self, from: data)
        #expect(back == s)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"password\""))   // no password field persisted
    }

    @Test func runFailResumeAndComplete() async throws {
        let (paths, src, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSteps(failOnce: "users")
        let migration = MySQLMigration(paths: paths, steps: fake)
        let options = MigrationOptions(method: .datadirUpgrade, source: src, sourceSockets: [])

        await #expect(throws: MigrationError.verifyFailed("injected failure in users")) {
            try await migration.run(options)
        }
        let failed = try #require(migration.loadState())
        #expect(failed.phase == .upgraded84)
        #expect(failed.failure?.step == "usersConverted")
        #expect(failed.schemas == ["app-two", "app_one", "empty_db"])
        #expect(failed.sourceFingerprint != nil)
        #expect(await fake.calls == ["copy", "upgrade8.4", "users", "finish"])

        let done = try await migration.run(options)
        #expect(done.phase == .activated && done.failure == nil && done.finishedAt != nil)
        #expect(await fake.calls == ["copy", "upgrade8.4", "users", "finish", "users", "upgrade9.7", "verify", "activate", "finish"])
        #expect(done.serverVersions == ["8.4": "8.4.11", "9.7": "9.7.2"])
        // Completed → a further run is a no-op.
        _ = try await migration.run(options)
        #expect(await fake.calls.count == 9)

        // Different settings need a discard first.
        await #expect(throws: MigrationError.stateMismatch("datadir from \(done.sourcePath) → 9.7")) {
            try await migration.run(MigrationOptions(method: .datadirUpgrade, source: src, targetBranch: "8.4", sourceSockets: []))
        }
        try await migration.discard()
        #expect(migration.loadState() == nil)
    }

    @Test func logicalPerDatabaseProgressSurvivesFailure() async throws {
        let (paths, src, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Logical needs a reachable source socket: a listening unix socket stands in for MAMP's server.
        let sock = dir.appending(path: "s.sock")
        let listener = try UnixListener(sock)
        defer { listener.close() }
        let fake = FakeSteps(failOnce: "b")
        let migration = MySQLMigration(paths: paths, steps: fake)
        let options = MigrationOptions(method: .logical, source: src, sourceSockets: [sock])
        await #expect(throws: LogicalMigrationError.importFailed(database: "b", output: "boom")) {
            try await migration.run(options)
        }
        let failed = try #require(migration.loadState())
        #expect(failed.phase == .importing)
        #expect(failed.doneDatabases == ["a"] && failed.inProgressDatabase == "b")
        let done = try await migration.run(options)
        #expect(done.phase == .imported && done.doneDatabases == ["a", "b", "c"])
    }

    @Test func refusesWhileSourceInUseAndDetectsChangedSource() async throws {
        let (paths, src, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSteps()
        let migration = MySQLMigration(paths: paths, steps: fake)
        let options = MigrationOptions(method: .datadirUpgrade, source: src, sourceSockets: [])

        let holder = try LockHolder(src.appending(path: "ibdata1"))
        await #expect(throws: MigrationError.self) { try await migration.run(options) }
        holder.stop()
        #expect(await fake.calls == ["finish"])   // refused before any step (finish = cleanup only)
        #expect(!FileManager.default.fileExists(atPath: MySQLMigration.datadirCopy(paths).path(percentEncoded: false)))

        // Record a fingerprint mid-copy, then change the source → resume must refuse.
        var state = MigrationState(method: .datadirUpgrade, sourcePath: src.standardizedFileURL.path(percentEncoded: false),
                                   targetBranch: "9.7")
        state.phase = .copying
        state.sourceFingerprint = SourceFingerprint.of(try DatadirCopier().scan(src))
        try await migration.saveState(state)
        let h = try FileHandle(forWritingTo: src.appending(path: "mysql.ibd"))
        try h.seekToEnd()
        try h.write(contentsOf: Data("more".utf8))
        try h.close()
        await #expect(throws: MigrationError.sourceChanged) { try await migration.run(options) }
        #expect(await fake.calls == ["finish", "finish"])
    }

    @Test func cancelStopsBetweenSteps() async throws {
        let (paths, src, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = SlowSteps()
        let migration = MySQLMigration(paths: paths, steps: slow)
        let options = MigrationOptions(method: .datadirUpgrade, source: src, sourceSockets: [])
        let task = Task { try await migration.run(options) }
        while await slow.started == false { try await Task.sleep(for: .milliseconds(10)) }
        await migration.cancel()
        await #expect(throws: MigrationError.cancelled) { try await task.value }
        let state = try #require(migration.loadState())
        #expect(state.phase == .copying)
        #expect(state.failure?.message == MigrationError.cancelled.localizedDescription)
        #expect(migration.runningPID() == nil)
    }
}

/// Copy step that waits for cancellation.
private actor SlowSteps: MySQLMigrationSteps {
    var started = false
    func copy(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        started = true
        while !ctx.cancel.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        throw MigrationError.cancelled
    }
    func upgrade(branch: String, _ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState { state }
    func convertUsers(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState { state }
    func verify(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState { state }
    func activate(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState { state }
    func importDatabases(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState { state }
    func finish(_ state: MigrationState, _ ctx: MigrationContext) async -> MigrationState { state }
}

/// Listening AF_UNIX socket (connectable, never accepts).
private final class UnixListener: Sendable {
    let fd: Int32

    init(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var sa = sockaddr_un()
        sa.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &sa.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 4) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func close() { Darwin.close(fd) }
}
