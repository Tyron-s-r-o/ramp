import Darwin
import Foundation

/// Classifies MySQL error-log lines (`2026-09-24T22:24:01Z 1 [System] [MY-011090] [Server] …`) — pure (plan 07-04).
public enum ErrorLogScanner {
    public enum Event: Sendable, Equatable {
        case error(String)
        /// Error that aborts startup (unknown storage engine, `Aborting`, DD upgrade failure).
        case fatal(String)
        case lowerCaseMismatch(String)
        case dictionaryUpgradeStarted(from: String, to: String)
        case dictionaryUpgradeCompleted(from: String, to: String)
        case serverUpgradeStarted(from: String, to: String)
        case serverUpgradeCompleted(from: String, to: String)
        case ready(version: String)
        /// `The plugin 'mysql_native_password' used to authenticate user 'u'@'h' is not loaded.`
        case unloadedAuthPlugin(user: String, host: String, plugin: String)
        case shutdownComplete
    }

    public static func classify(_ line: String) -> Event? {
        let message = Self.message(of: line)
        if line.contains("[ERROR]") {
            if message.contains("lower_case_table_names") { return .lowerCaseMismatch(message) }
            if message.contains("Unknown/unsupported storage engine") || message.hasPrefix("Aborting")
                || message.contains("Data Dictionary initialization failed")
                || message.contains("Failed to upgrade") || message.contains("upgrade failed") {
                return .fatal(message)
            }
            return .error(message)
        }
        if let (a, b) = quotedPair(message, prefix: "Data dictionary upgrading from version ") {
            return .dictionaryUpgradeStarted(from: a, to: b)
        }
        if message.hasSuffix("completed."), let (a, b) = quotedPair(message, prefix: "Data dictionary upgrade from version ") {
            return .dictionaryUpgradeCompleted(from: a, to: b)
        }
        if let (a, b) = quotedPair(message, prefix: "Server upgrade from ") {
            if message.hasSuffix("started.") { return .serverUpgradeStarted(from: a, to: b) }
            if message.hasSuffix("completed.") { return .serverUpgradeCompleted(from: a, to: b) }
        }
        if message.contains("ready for connections"), let r = message.range(of: "Version: '") {
            let rest = message[r.upperBound...]
            return .ready(version: String(rest.prefix { $0 != "'" }))
        }
        if message.hasPrefix("The plugin '"), message.contains("used to authenticate user"),
           message.contains("is not loaded") {
            let q = quoted(message)
            if q.count >= 3 { return .unloadedAuthPlugin(user: q[1], host: q[2], plugin: q[0]) }
        }
        if message.contains("Shutdown complete") { return .shutdownComplete }
        return nil
    }

    public static func scan(_ text: String) -> [Event] {
        text.split(whereSeparator: \.isNewline).compactMap { classify(String($0)) }
    }

    /// Error / fatal / lower_case events: the upgrade must be treated as failed.
    public static func failures(_ events: [Event]) -> [String] {
        events.compactMap {
            switch $0 {
            case .error(let m), .fatal(let m), .lowerCaseMismatch(let m): m
            default: nil
            }
        }
    }

    /// Text after the leading `[Level] [MY-…] [Subsystem]` bracket groups, else the whole line.
    static func message(of line: String) -> String {
        guard let first = line.firstIndex(of: "[") else { return line }
        var rest = line[first...]
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func quoted(_ s: String) -> [String] {
        let parts = s.split(separator: "'", omittingEmptySubsequences: false)
        return stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) }
    }

    private static func quotedPair(_ message: String, prefix: String) -> (String, String)? {
        guard message.hasPrefix(prefix) else { return nil }
        let q = quoted(message)
        return q.count >= 2 ? (q[0], q[1]) : nil
    }
}

public enum MySQLUpgradeError: Error, LocalizedError, Equatable {
    case binaryMissing(String)
    case alreadyRunning(String)
    case launchFailed(String)
    case exited(status: Int32, logTail: String)
    case lowerCaseTableNames(String)
    case upgradeErrors([String], logTail: String)
    case timeout(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let p): "MySQL server binary missing: \(p)"
        case .alreadyRunning(let s): "Another temporary migration server is still running (\(s))."
        case .launchFailed(let m): "Cannot start the temporary MySQL server: \(m)"
        case .exited(let status, let tail): "The temporary MySQL server exited (status \(status)) before it was ready:\n\(tail)"
        case .lowerCaseTableNames(let m):
            "lower_case_table_names differs between this server and the datadir (\(m)). The MAMP datadir was "
                + "initialized with the macOS default (2); RAMP starts MySQL with the platform default as well — "
                + "check for a lower_case_table_names override."
        case .upgradeErrors(let lines, let tail):
            "The MySQL upgrade logged errors:\n" + lines.joined(separator: "\n") + "\n--- log tail ---\n" + tail
        case .timeout(let what): "Timed out waiting for \(what)."
        case .cancelled: "Cancelled."
        }
    }
}

/// Runs a temporary `mysqld` on a datadir copy for an in-place upgrade (`--upgrade=AUTO`): no networking,
/// no binlog, own socket/pid in `run/`, error log `<logs>/mamp-import-<branch>.err` (plan 07-04).
/// Shutdown is SIGTERM (clean, honours `--innodb-fast-shutdown=0`) — no credentials needed.
public actor MySQLUpgradeRunner {
    public struct Server: Sendable, Equatable {
        public var branch: String
        public var socket: URL
        public var pid: Int32
        public var version: String
        public var errorLog: URL
        /// Events logged by this start (log offset at launch → ready).
        public var events: [ErrorLogScanner.Event]
    }

    public let paths: Paths
    private var process: Process?
    public private(set) var current: Server?

    public init(paths: Paths) {
        self.paths = paths
    }

    public func socket(branch: String) -> URL {
        paths.runDir.appending(path: "mamp-import-\(branch).sock", directoryHint: .notDirectory)
    }
    public func pidFile(branch: String) -> URL {
        paths.runDir.appending(path: "mamp-import-\(branch).pid", directoryHint: .notDirectory)
    }
    public func errorLog(branch: String) -> URL { paths.log("mamp-import-\(branch).err") }

    /// mysqld argv (pure). 8.4 additionally enables `mysql_native_password` (MAMP accounts use it).
    public static func arguments(branch: String, basedir: URL, datadir: URL, socket: URL, pidFile: URL,
                                 errorLog: URL, tmpdir: URL, extraArgs: [String] = []) -> [String] {
        var args = [
            "--no-defaults",
            "--basedir=\(ConfigText.path(basedir))",
            "--datadir=\(ConfigText.path(datadir))",
            "--socket=\(ConfigText.path(socket))",
            "--pid-file=\(ConfigText.path(pidFile))",
            "--skip-networking",
            "--skip-log-bin",
            "--mysqlx=OFF",
            "--upgrade=AUTO",
            "--log-error=\(ConfigText.path(errorLog))",
            "--innodb-fast-shutdown=0",
            "--tmpdir=\(ConfigText.path(tmpdir))",
        ]
        if branch == "8.4" { args.append("--mysql-native-password=ON") }
        return args + extraArgs
    }

    /// Starts `<root>/mysql/<branch>/current/bin/mysqld` on `datadir` and waits until the socket accepts
    /// connections. `tick(elapsed, lastLogLine)` is called about once per second while waiting.
    public func start(branch: String, datadir: URL, timeout: Duration = .seconds(3600), extraArgs: [String] = [],
                      tick: @Sendable (Duration, String?) -> Void = { _, _ in }) async throws -> Server {
        if let current, current.branch == branch, process?.isRunning == true { return current }
        await stop()
        let basedir = paths.current(component: "mysql", branch: branch).resolvingSymlinksInPath()
        let mysqld = basedir.appending(path: "bin/mysqld", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: mysqld.path(percentEncoded: false)) else {
            throw MySQLUpgradeError.binaryMissing(mysqld.path(percentEncoded: false))
        }
        try paths.ensureDirectories()
        let sock = socket(branch: branch), pid = pidFile(branch: branch), log = errorLog(branch: branch)
        try paths.validateSocketPath(sock)
        try await stopStale(pidFile: pid)
        if SocketAddress.canConnectUnix(path: sock.path(percentEncoded: false)) {
            throw MySQLUpgradeError.alreadyRunning(sock.path(percentEncoded: false))
        }
        unlink(sock.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let offset = Self.fileSize(log)

        let p = Process()
        p.executableURL = mysqld
        p.arguments = Self.arguments(branch: branch, basedir: basedir, datadir: datadir, socket: sock, pidFile: pid,
                                     errorLog: log, tmpdir: paths.tmp, extraArgs: extraArgs)
        p.environment = ServiceSpec.baseEnvironment()
        p.currentDirectoryURL = paths.tmp
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw MySQLUpgradeError.launchFailed(error.localizedDescription) }
        process = p

        let clock = ContinuousClock()
        let started = clock.now
        var lastTick = started
        while true {
            if Task.isCancelled {
                await stop()
                throw MySQLUpgradeError.cancelled
            }
            if !p.isRunning {
                process = nil
                let text = Self.read(log, from: offset)
                let events = ErrorLogScanner.scan(text)
                if let lc = events.first(where: { if case .lowerCaseMismatch = $0 { true } else { false } }),
                   case .lowerCaseMismatch(let m) = lc {
                    throw MySQLUpgradeError.lowerCaseTableNames(m)
                }
                throw MySQLUpgradeError.exited(status: p.terminationStatus, logTail: Self.tail(text))
            }
            if SocketAddress.canConnectUnix(path: sock.path(percentEncoded: false)) {
                let text = Self.read(log, from: offset)
                let events = ErrorLogScanner.scan(text)
                let failures = ErrorLogScanner.failures(events)
                let version = events.compactMap { if case .ready(let v) = $0 { v } else { nil } }.last ?? ""
                let server = Server(branch: branch, socket: sock, pid: p.processIdentifier, version: version,
                                    errorLog: log, events: events)
                current = server
                if !failures.isEmpty {
                    await stop()
                    throw MySQLUpgradeError.upgradeErrors(failures, logTail: Self.tail(text))
                }
                return server
            }
            let now = clock.now
            if now - started > timeout {
                await stop()
                throw MySQLUpgradeError.timeout("MySQL \(branch) to become ready")
            }
            if now - lastTick >= .seconds(1) {
                lastTick = now
                let last = Self.read(log, from: offset).split(whereSeparator: \.isNewline).last.map(String.init)
                tick(now - started, last)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// SIGTERM + wait for exit (clean slow shutdown). No-op when nothing runs.
    public func stop(timeout: Duration = .seconds(1800)) async {
        defer {
            process = nil
            current = nil
        }
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGTERM)
        let clock = ContinuousClock()
        let started = clock.now
        while p.isRunning, clock.now - started < timeout {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// A temp server of an earlier (crashed) run still holding the pid file → SIGTERM it and wait.
    private func stopStale(pidFile: URL) async throws {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
        else { return }
        guard let exe = PortProbe.executablePath(pid: pid), exe.hasSuffix("/mysqld"),
              PortProbe.isUnder(exe, root: paths.root) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<9000 where kill(pid, 0) == 0 {   // ≤ 30 min
            try? await Task.sleep(for: .milliseconds(200))
        }
        if kill(pid, 0) == 0 { throw MySQLUpgradeError.alreadyRunning("pid \(pid)") }
    }

    static func fileSize(_ url: URL) -> UInt64 {
        var st = stat()
        return stat(url.path(percentEncoded: false), &st) == 0 ? UInt64(st.st_size) : 0
    }

    static func read(_ url: URL, from offset: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func tail(_ text: String, lines: Int = 25) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}
