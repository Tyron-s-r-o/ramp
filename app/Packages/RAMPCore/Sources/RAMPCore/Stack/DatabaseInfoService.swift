import Foundation
import Synchronization

/// Size of one MySQL schema (`information_schema.tables`).
public struct DatabaseSize: Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var bytes: Int64
    public var tables: Int

    public var id: String { name }

    public init(name: String, bytes: Int64, tables: Int) {
        self.name = name
        self.bytes = bytes
        self.tables = tables
    }
}

public struct RedisInfo: Sendable, Equatable {
    public var version: String?
    public var usedMemoryHuman: String?
    /// Sum of `keys=` over every `dbN` line of the Keyspace section.
    public var keys: Int

    public init(version: String? = nil, usedMemoryHuman: String? = nil, keys: Int = 0) {
        self.version = version
        self.usedMemoryHuman = usedMemoryHuman
        self.keys = keys
    }
}

public enum DatabaseInfoError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case notRunning(String)
    case commandFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let c): "\(c) is not installed."
        case .notRunning(let c): "\(c) is not running."
        case .commandFailed(let out): out
        case .timedOut(let what): "\(what) did not answer within the timeout."
        }
    }
}

/// Read-only MySQL / Redis introspection for the Databáza section (+ Redis FLUSHALL).
///
/// MySQL: the RAMP `mysql` client over the unix socket; the root password goes into a 0600 temp
/// `--defaults-file` (deleted right after the call), never into argv. Redis: the package's `redis-cli`
/// (it ships in every RAMP redis package — no hand-written RESP client needed).
public actor DatabaseInfoService {
    public static let systemSchemas: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]
    public static let timeout: Duration = .seconds(15)

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: MySQL

    public func mysqlDatabases(_ config: RampConfig, includeSystem: Bool = false) async throws -> [DatabaseSize] {
        let sql = "SELECT table_schema, COALESCE(SUM(data_length+index_length),0), COUNT(*) "
            + "FROM information_schema.tables GROUP BY table_schema ORDER BY table_schema"
        return Self.parseMySQLBatch(try await mysqlQuery(sql, config: config), includeSystem: includeSystem)
    }

    public func mysqlVersion(_ config: RampConfig) async throws -> String {
        try await mysqlQuery("SELECT VERSION()", config: config).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RAMP `mysql` client of the configured branch.
    public nonisolated func mysqlClient(_ config: RampConfig) -> URL {
        paths.current(component: "mysql", branch: config.mysql.branch).appending(path: "bin/mysql")
    }

    private func mysqlQuery(_ sql: String, config: RampConfig) async throws -> String {
        let branch = config.mysql.branch
        guard config.installed["mysql"]?[branch] != nil else { throw DatabaseInfoError.notInstalled("MySQL") }
        let socket = paths.mysqlSocket(major: branch)
        guard FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)) else {
            throw DatabaseInfoError.notRunning("MySQL")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.tmp, withIntermediateDirectories: true)
        let cnf = paths.tmp.appending(path: ".mysql-info-\(UUID().uuidString).cnf", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: cnf) }
        let text = ConfigText(dialect: .backslash, separator: "=", commentPrefix: "#")
        let body = "[client]\nuser=root\npassword=\(try text.quote(config.mysql.rootPassword, key: "mysql.rootPassword"))\n"
            + "socket=\(try text.quote(ConfigText.path(socket), key: "socket"))\n"
        guard fm.createFile(atPath: cnf.path(percentEncoded: false), contents: Data(body.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw DatabaseInfoError.commandFailed("Cannot write a temporary MySQL client config in \(paths.tmp.path)")
        }
        // --defaults-file (not -extra-file): a user's ~/.my.cnf must not override the RAMP credentials.
        let result = try await Self.run(
            [mysqlClient(config).path(percentEncoded: false), "--defaults-file=\(ConfigText.path(cnf))",
             "--batch", "--skip-column-names", "--connect-timeout=5", "-e", sql],
            what: "MySQL", tempDir: paths.tmp)
        guard result.status == 0 else {
            throw DatabaseInfoError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    // MARK: Redis

    public func redisInfo(_ config: RampConfig) async throws -> RedisInfo {
        let result = try await redisCLI(config, ["INFO"])
        let info = Self.parseRedisInfo(result)
        guard info.version != nil else {
            throw DatabaseInfoError.commandFailed(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return info
    }

    public func redisFlushAll(_ config: RampConfig) async throws {
        let out = try await redisCLI(config, ["FLUSHALL"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard out == "OK" else { throw DatabaseInfoError.commandFailed(out) }
    }

    private func redisCLI(_ config: RampConfig, _ command: [String]) async throws -> String {
        guard let branch = GeneratorSupport.highestBranch(config, component: "redis") else {
            throw DatabaseInfoError.notInstalled("Redis")
        }
        let cli = paths.current(component: "redis", branch: branch).appending(path: "bin/redis-cli")
        let host = ServiceSpecFactory.connectHost(config.redis.bindAddress)
        let result = try await Self.run(
            [cli.path(percentEncoded: false), "-h", host, "-p", String(config.redis.port)] + command,
            what: "Redis", tempDir: paths.tmp)
        // redis-cli exits 0 even on "Could not connect"; the caller validates the payload.
        guard result.status == 0, !result.output.hasPrefix("Could not connect") else {
            if result.output.contains("Could not connect") || result.output.contains("Connection refused") {
                throw DatabaseInfoError.notRunning("Redis")
            }
            throw DatabaseInfoError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    // MARK: Parsing (pure)

    /// `mysql --batch --skip-column-names` output of `schema \t bytes \t tables` rows. Batch mode escapes
    /// tab / newline / backslash in values as `\t` / `\n` / `\\`; a raw tab inside a name is tolerated too
    /// (the last two fields are the numbers).
    public static func parseMySQLBatch(_ output: String, includeSystem: Bool = false) -> [DatabaseSize] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> DatabaseSize? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let tables = Int(fields[fields.count - 1].trimmingCharacters(in: .whitespaces)) else { return nil }
            let bytesField = fields[fields.count - 2].trimmingCharacters(in: .whitespaces)
            guard let bytes = Int64(bytesField) ?? Decimal(string: bytesField).map({ NSDecimalNumber(decimal: $0).int64Value })
            else { return nil }
            let name = unescapeBatch(fields.dropLast(2).joined(separator: "\t"))
            guard !name.isEmpty, includeSystem || !systemSchemas.contains(name.lowercased()) else { return nil }
            return DatabaseSize(name: name, bytes: bytes, tables: tables)
        }
    }

    static func unescapeBatch(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        var escaping = false
        for ch in value {
            if escaping {
                switch ch {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "0": out.append("\0")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    /// `INFO` reply (`key:value` lines, `# Section` headers, CRLF).
    public static func parseRedisInfo(_ output: String) -> RedisInfo {
        var info = RedisInfo()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            switch key {
            case "redis_version": info.version = value
            case "used_memory_human": info.usedMemoryHuman = value
            default:
                guard key.hasPrefix("db"), Int(key.dropFirst(2)) != nil else { continue }
                for part in value.split(separator: ",") {
                    let kv = part.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "keys", let n = Int(kv[1]) { info.keys += n }
                }
            }
        }
        return info
    }

    // MARK: Process

    struct Output: Sendable {
        var status: Int32
        var output: String
    }

    /// argv only (no shell), combined stdout+stderr via a temp file, killed after `timeout`.
    static func run(_ argv: [String], what: String, timeout: Duration = DatabaseInfoService.timeout,
                    tempDir: URL) async throws -> Output {
        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outURL = tempDir.appending(path: ".dbinfo-\(UUID().uuidString).out", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: outURL) }
        guard fm.createFile(atPath: outURL.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw DatabaseInfoError.commandFailed("Cannot create a temporary file in \(tempDir.path)")
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let p = Process()
        p.executableURL = URL(filePath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = ServiceSpec.baseEnvironment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = outHandle

        let box = ProcessBox(p)
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            box.terminateOnTimeout()
        }
        defer { timer.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { proc in continuation.resume(returning: proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                continuation.resume(throwing: DatabaseInfoError.commandFailed(
                    "Cannot run \(argv[0]): \(error.localizedDescription)"))
            }
        }
        try? outHandle.close()
        if box.didTimeOut { throw DatabaseInfoError.timedOut(what) }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return Output(status: status, output: text)
    }
}

/// Lets the timeout task terminate the child and remembers that it did.
private final class ProcessBox: Sendable {
    private let process: Process
    private let timedOut = Mutex(false)

    init(_ process: Process) { self.process = process }

    func terminateOnTimeout() {
        guard process.isRunning else { return }
        timedOut.withLock { $0 = true }
        process.terminate()
    }

    var didTimeOut: Bool { timedOut.withLock { $0 } }
}
