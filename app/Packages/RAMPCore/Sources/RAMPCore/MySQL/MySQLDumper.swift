import Darwin
import Foundation

/// Runs a process whose stdout goes to a file (dumps); `ProcessRunResult.output` carries stderr only.
public protocol StreamingProcessRunning: Sendable {
    func run(_ argv: [String], environment: [String: String], stdout: URL, timeout: Duration) async -> ProcessRunResult
}

/// `Process`-based runner: stdout → `stdout` file (must exist), stderr → temp file, SIGTERM/SIGKILL on timeout.
public struct SystemStreamingProcessRunner: StreamingProcessRunning {
    public let tempDir: URL

    public init(tempDir: URL) { self.tempDir = tempDir }

    public func run(_ argv: [String], environment: [String: String], stdout: URL,
                    timeout: Duration) async -> ProcessRunResult {
        guard let exe = argv.first else { return ProcessRunResult(status: -1, output: "empty argv") }
        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let errURL = tempDir.appending(path: ".stream-\(UUID().uuidString).err", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: errURL) }
        guard fm.createFile(atPath: errURL.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]),
              let errHandle = try? FileHandle(forWritingTo: errURL),
              let outHandle = try? FileHandle(forWritingTo: stdout) else {
            return ProcessRunResult(status: -1, output: "cannot open output files")
        }
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = errHandle

        let done = DoneFlag()
        var launchError: String?
        let status: Int32 = await withCheckedContinuation { continuation in
            p.terminationHandler = { proc in
                done.set()
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                launchError = error.localizedDescription
                done.set()
                continuation.resume(returning: -1)
                return
            }
            let pid = p.processIdentifier
            Task.detached {
                let deadline = ContinuousClock.now + timeout
                while !done.isSet, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(200)) }
                guard !done.isSet else { return }
                done.markTimedOut()
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(5))
                if !done.isSet { kill(pid, SIGKILL) }
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        if let launchError { return ProcessRunResult(status: -1, output: "cannot run \(exe): \(launchError)") }
        let text = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessRunResult(status: status, output: text, timedOut: done.timedOut)
    }

    private final class DoneFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var didTimeOut = false
        var isSet: Bool { lock.withLock { done } }
        var timedOut: Bool { lock.withLock { didTimeOut } }
        func set() { lock.withLock { done = true } }
        func markTimedOut() { lock.withLock { didTimeOut = true } }
    }
}

public struct DumpResult: Sendable, Equatable {
    public let file: URL
    public let bytes: Int64
}

public enum DumpError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case notRunning(String)
    case cannotCreate(String)
    /// mysqldump exited non-zero (stderr tail).
    case failed(status: Int32, output: String)
    /// Exit 0 but the file does not end with "-- Dump completed" (truncated / killed).
    case incomplete(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let branch): return "MySQL \(branch) is not installed; nothing to dump."
        case .notRunning(let branch): return "MySQL \(branch) is not running; start it so the backup dump can be taken first."
        case .cannotCreate(let path): return "Cannot create the dump file \(path)."
        case .failed(let status, let output): return "mysqldump failed (exit \(status)): \(output)"
        case .incomplete(let path): return "The dump \(path) is incomplete (no \"Dump completed\" trailer)."
        case .timedOut: return "mysqldump did not finish in time."
        }
    }
}

/// Abstraction for `UpdateService` (tests inject a fake).
public protocol MySQLDumping: Sendable {
    /// Verified `--all-databases` dump of the configured MySQL into `<root>/backups`, keeping the last 3.
    func automaticDump(config: RampConfig) async throws -> DumpResult
}

/// `mysqldump --all-databases …` of RAMP's MySQL (plan 07-02). The password travels via `MYSQL_PWD` only
/// (never argv — visible in `ps`); output is streamed into a 0600 file; success = exit 0 + trailing
/// `-- Dump completed`; any failure deletes the partial file.
public struct MySQLDumper: MySQLDumping {
    public static let dumpOptions = [
        "--all-databases", "--routines", "--events", "--triggers", "--single-transaction", "--hex-blob",
        "--set-gtid-purged=OFF", "--default-character-set=utf8mb4",
    ]
    public static let automaticPrefix = "mysql-"
    public static let keepAutomatic = 3

    public let paths: Paths
    private let runner: any StreamingProcessRunning
    private let timeout: Duration

    public init(paths: Paths, runner: (any StreamingProcessRunning)? = nil, timeout: Duration = .seconds(3600)) {
        self.paths = paths
        self.runner = runner ?? SystemStreamingProcessRunner(tempDir: paths.tmp)
        self.timeout = timeout
    }

    public func mysqldump(branch: String) -> URL {
        paths.current(component: "mysql", branch: branch).appending(path: "bin/mysqldump")
    }

    /// Dumps everything reachable through `socket` into `url`.
    @discardableResult
    public func dumpAll(to url: URL, socket: URL, user: String, password: String,
                       branch: String) async throws -> DumpResult {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DumpError.cannotCreate(path)
        }
        var env = ServiceSpec.baseEnvironment()
        env["MYSQL_PWD"] = password
        // --no-defaults first: a user's ~/.my.cnf must not redirect the dump.
        let argv = [mysqldump(branch: branch).path(percentEncoded: false), "--no-defaults",
                    "--user=\(user)", "--socket=\(socket.path(percentEncoded: false))"] + Self.dumpOptions
        let result = await runner.run(argv, environment: env, stdout: url, timeout: timeout)
        do {
            if result.timedOut { throw DumpError.timedOut }
            guard result.status == 0 else {
                throw DumpError.failed(status: result.status, output: Self.tail(result.output))
            }
            guard Self.endsWithCompletion(url) else { throw DumpError.incomplete(path) }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return DumpResult(file: url, bytes: size)
    }

    public func automaticDump(config: RampConfig) async throws -> DumpResult {
        let branch = config.mysql.branch
        guard config.installed["mysql"]?[branch] != nil else { throw DumpError.notInstalled(branch) }
        let socket = paths.mysqlSocket(major: branch)
        guard SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false)) else {
            throw DumpError.notRunning(branch)
        }
        let url = Self.automaticDumpURL(paths: paths, branch: branch)
        let result = try await dumpAll(to: url, socket: socket, user: "root", password: config.mysql.rootPassword,
                                       branch: branch)
        Self.pruneAutomaticDumps(in: paths.backups, keep: Self.keepAutomatic)
        return result
    }

    /// `<root>/backups/mysql-<branch>-<yyyyMMdd-HHmmss>.sql`
    public static func automaticDumpURL(paths: Paths, branch: String, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return paths.backups.appending(path: "\(automaticPrefix)\(branch)-\(f.string(from: date)).sql",
                                       directoryHint: .notDirectory)
    }

    /// Keeps the newest `keep` automatic dumps (`mysql-*.sql`, by modification date then name).
    @discardableResult
    public static func pruneAutomaticDumps(in dir: URL, keep: Int) -> [URL] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix(automaticPrefix) && $0.hasSuffix(".sql") }
        let dated = names.map { name -> (URL, Date) in
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            let date = (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
                ?? .distantPast
            return (url, date)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
        let doomed = dated.dropFirst(max(keep, 0)).map(\.0)
        for url in doomed { try? fm.removeItem(at: url) }
        return doomed
    }

    /// Last non-empty line of the file contains `-- Dump completed`.
    static func endsWithCompletion(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 512
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let last = text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last?.contains("-- Dump completed") ?? false
    }

    static func tail(_ text: String, lines: Int = 15) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}
