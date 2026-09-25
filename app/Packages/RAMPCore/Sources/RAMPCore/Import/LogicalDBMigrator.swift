import Darwin
import Foundation

/// Rewrites `DEFINER=`user`@`host`` to `DEFINER=CURRENT_USER` in mysqldump output (views, triggers, routines,
/// events) — MAMP's definer accounts do not exist in RAMP (plan 07-04, method b). Pure.
public enum DefinerFilter {
    public static func rewrite(_ line: String) -> String {
        String(decoding: rewrite(bytes: Array(line.utf8)), as: UTF8.self)
    }

    private static let needle = Array("DEFINER=".utf8)
    private static let replacement = Array("DEFINER=CURRENT_USER".utf8)
    private static let backtick = UInt8(ascii: "`")
    private static let at = UInt8(ascii: "@")

    static func rewrite(bytes: [UInt8]) -> [UInt8] {
        guard contains(bytes, needle) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if matches(bytes, at: i, needle), let end = definerEnd(bytes, from: i + needle.count) {
                out += replacement
                i = end
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// End index of `` `u`@`h` `` starting at `start`, nil when not that shape (e.g. already CURRENT_USER).
    private static func definerEnd(_ b: [UInt8], from start: Int) -> Int? {
        guard let userEnd = quotedEnd(b, from: start), userEnd < b.count, b[userEnd] == at,
              let hostEnd = quotedEnd(b, from: userEnd + 1) else { return nil }
        return hostEnd
    }

    /// Index after a backtick-quoted identifier (`` `` `` escapes a backtick).
    private static func quotedEnd(_ b: [UInt8], from start: Int) -> Int? {
        guard start < b.count, b[start] == backtick else { return nil }
        var i = start + 1
        while i < b.count {
            if b[i] == backtick {
                if i + 1 < b.count, b[i + 1] == backtick { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return nil
    }

    private static func matches(_ b: [UInt8], at i: Int, _ n: [UInt8]) -> Bool {
        guard i + n.count <= b.count else { return false }
        for k in 0..<n.count where b[i + k] != n[k] { return false }
        return true
    }

    static func contains(_ b: [UInt8], _ n: [UInt8]) -> Bool {
        guard b.count >= n.count else { return false }
        for i in 0...(b.count - n.count) where b[i] == n[0] && matches(b, at: i, n) { return true }
        return false
    }
}

/// Streaming line filter for the dump pipe: `INSERT …` lines (the bulk, possibly huge) are passed through
/// without buffering, every other line goes through `DefinerFilter`.
struct DefinerStreamFilter {
    private var line: [UInt8] = []
    private var passthrough = false
    private static let insert = Array("INSERT ".utf8)
    private static let newline = UInt8(ascii: "\n")

    mutating func feed(_ chunk: Data) -> Data {
        var out = Data()
        out.reserveCapacity(chunk.count + 64)
        chunk.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            while i < n {
                if passthrough {
                    var j = i
                    while j < n, b[j] != Self.newline { j += 1 }
                    let end = j < n ? j + 1 : n
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<end]))
                    if j < n { passthrough = false }
                    i = end
                    continue
                }
                if line.count < Self.insert.count {
                    // Line start: decide INSERT (stream through) vs. anything else (buffer + filter).
                    let byte = b[i]
                    i += 1
                    line.append(byte)
                    if byte == Self.newline {
                        out.append(contentsOf: DefinerFilter.rewrite(bytes: line))
                        line.removeAll(keepingCapacity: true)
                    } else if line.count == Self.insert.count, line == Self.insert {
                        out.append(contentsOf: line)
                        line.removeAll(keepingCapacity: true)
                        passthrough = true
                    }
                    continue
                }
                var j = i
                while j < n, b[j] != Self.newline { j += 1 }
                if j < n {
                    line.append(contentsOf: UnsafeBufferPointer(rebasing: b[i...j]))
                    out.append(contentsOf: DefinerFilter.rewrite(bytes: line))
                    line.removeAll(keepingCapacity: true)
                    i = j + 1
                } else {
                    line.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<n]))
                    i = n
                }
            }
        }
        return out
    }

    mutating func finish() -> Data {
        defer { line.removeAll() }
        return Data(DefinerFilter.rewrite(bytes: line))
    }
}

public enum LogicalMigrationError: Error, LocalizedError, Equatable {
    case sourceUnreachable(String)
    case targetUnreachable(String)
    case dumpFailed(database: String, output: String)
    case importFailed(database: String, output: String)
    case verifyFailed(database: String, source: Int, target: Int)
    case targetDatabaseExists([String])
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceUnreachable(let s): "The MAMP MySQL server is not reachable (\(s)) — start MySQL in MAMP PRO."
        case .targetUnreachable(let s): "RAMP MySQL is not reachable (\(s))."
        case .dumpFailed(let db, let out): "mysqldump of \(db) failed:\n\(out)"
        case .importFailed(let db, let out): "Import of \(db) failed:\n\(out)"
        case .verifyFailed(let db, let s, let t): "\(db): \(s) tables in MAMP, \(t) in RAMP after the import."
        case .targetDatabaseExists(let names):
            "RAMP MySQL already has these databases: \(names.joined(separator: ", ")) — drop them or allow replacing."
        case .cancelled: "Cancelled."
        }
    }
}

/// Connection to one server over its unix socket.
public struct MySQLEndpoint: Sendable {
    public var socket: URL
    public var user: String
    public var password: String

    public init(socket: URL, user: String = "root", password: String) {
        self.socket = socket
        self.user = user
        self.password = password
    }
}

public struct SourceDatabase: Sendable, Equatable {
    public var name: String
    public var charset: String
    public var collation: String
}

/// Method (b): per-DB `mysqldump` of the running MAMP server piped (no temp file) through `DefinerFilter`
/// into RAMP's `mysql` client (plan 07-04).
public struct LogicalDBMigrator: Sendable {
    public static let importSQLMode = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"

    /// RAMP client binaries (`<root>/mysql/<branch>/current/bin`).
    public var binDir: URL
    /// MAMP's 8.0 `mysqldump`, used when the RAMP one fails against the 8.0 server.
    public var fallbackDump: URL?
    public var tempDir: URL

    public init(binDir: URL, fallbackDump: URL?, tempDir: URL) {
        self.binDir = binDir
        self.fallbackDump = fallbackDump
        self.tempDir = tempDir
    }

    func client(_ e: MySQLEndpoint) -> MySQLClient {
        MySQLClient(binary: binDir.appending(path: "mysql"), socket: e.socket, user: e.user, password: e.password,
                    tempDir: tempDir)
    }

    public func databases(_ source: MySQLEndpoint) async throws -> [SourceDatabase] {
        let rows = try await client(source).rows(
            "SELECT schema_name, default_character_set_name, default_collation_name FROM information_schema.schemata "
                + "WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
        return rows.filter { $0.count >= 3 }.map { SourceDatabase(name: $0[0], charset: $0[1], collation: $0[2]) }
    }

    public func tableCounts(_ endpoint: MySQLEndpoint) async throws -> [String: Int] {
        let rows = try await client(endpoint).rows(
            "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN "
                + "('mysql','sys','performance_schema','information_schema') GROUP BY table_schema;")
        return Dictionary(rows.compactMap { r in r.count >= 2 ? (r[0], Int(r[1]) ?? 0) : nil }, uniquingKeysWith: { a, _ in a })
    }

    public func dropDatabase(_ name: String, target: MySQLEndpoint) async throws {
        _ = try await client(target).execute("DROP DATABASE IF EXISTS \(SQL.identifier(name));")
    }

    /// Dumps `db` from `source` into `target` (database created with the source charset/collation).
    /// - Returns: true when MAMP's 8.0 mysqldump had to be used.
    @discardableResult
    public func migrate(_ db: SourceDatabase, source: MySQLEndpoint, target: MySQLEndpoint,
                        cancel: CancelFlag = CancelFlag()) async throws -> Bool {
        let create = "CREATE DATABASE IF NOT EXISTS \(SQL.identifier(db.name)) CHARACTER SET \(SQL.identifier(db.charset)) "
            + "COLLATE \(SQL.identifier(db.collation));"
        _ = try await client(target).execute(create)
        let primary = binDir.appending(path: "mysqldump")
        do {
            try await pipe(db.name, dump: primary, source: source, target: target, cancel: cancel)
            return false
        } catch LogicalMigrationError.dumpFailed(let name, let output) where fallbackDump != nil {
            guard let fallback = fallbackDump, FileManager.default.isExecutableFile(atPath: fallback.path(percentEncoded: false))
            else { throw LogicalMigrationError.dumpFailed(database: name, output: output) }
            try await dropDatabase(db.name, target: target)
            _ = try await client(target).execute(create)
            try await pipe(db.name, dump: fallback, source: source, target: target, cancel: cancel)
            return true
        }
    }

    static func dumpArguments(database: String) -> [String] {
        ["--single-transaction", "--routines", "--triggers", "--events", "--hex-blob", "--set-gtid-purged=OFF",
         "--no-tablespaces", "--column-statistics=0", "--default-character-set=utf8mb4", "--", database]
    }

    static func importArguments(database: String) -> [String] {
        ["--init-command=SET SESSION sql_mode='\(importSQLMode)'", "--max-allowed-packet=1G",
         "--default-character-set=utf8mb4", "--", database]
    }

    private func pipe(_ database: String, dump: URL, source: MySQLEndpoint, target: MySQLEndpoint,
                      cancel: CancelFlag) async throws {
        let srcCreds = try MySQLCredentialsFile(directory: tempDir, user: source.user, password: source.password,
                                                socket: source.socket, pluginDir: MySQLCredentialsFile.pluginDir(forBinary: dump))
        defer { srcCreds.remove() }
        let importer = binDir.appending(path: "mysql")
        let dstCreds = try MySQLCredentialsFile(directory: tempDir, user: target.user, password: target.password,
                                                socket: target.socket, pluginDir: MySQLCredentialsFile.pluginDir(forBinary: importer))
        defer { dstCreds.remove() }
        let dumpArgv = [dump.path(percentEncoded: false), srcCreds.argument] + Self.dumpArguments(database: database)
        let importArgv = [importer.path(percentEncoded: false), dstCreds.argument]
            + Self.importArguments(database: database)
        let tempDir = self.tempDir
        let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<PipeResult, any Error>) in
            Thread.detachNewThread {
                c.resume(with: Result { try Self.runPipe(dumpArgv, importArgv, tempDir: tempDir, cancel: cancel) })
            }
        }
        if result.cancelled { throw LogicalMigrationError.cancelled }
        if result.dumpStatus != 0 { throw LogicalMigrationError.dumpFailed(database: database, output: result.dumpOutput) }
        if result.importStatus != 0 {
            throw LogicalMigrationError.importFailed(database: database, output: result.importOutput)
        }
    }

    struct PipeResult: Sendable {
        var dumpStatus: Int32
        var importStatus: Int32
        var dumpOutput: String
        var importOutput: String
        var cancelled: Bool
    }

    /// Blocking: mysqldump stdout → filter → mysql stdin. Runs on its own thread.
    static func runPipe(_ dumpArgv: [String], _ importArgv: [String], tempDir: URL, cancel: CancelFlag) throws -> PipeResult {
        let fm = FileManager.default
        let dumpErr = tempDir.appending(path: ".dump-\(UUID().uuidString).err")
        let importOut = tempDir.appending(path: ".import-\(UUID().uuidString).out")
        for url in [dumpErr, importOut] {
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        }
        defer {
            try? fm.removeItem(at: dumpErr)
            try? fm.removeItem(at: importOut)
        }
        let dumpErrHandle = try FileHandle(forWritingTo: dumpErr)
        let importOutHandle = try FileHandle(forWritingTo: importOut)
        defer {
            try? dumpErrHandle.close()
            try? importOutHandle.close()
        }
        let dumpOut = Pipe(), importIn = Pipe()
        _ = fcntl(importIn.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let importer = Process()
        importer.executableURL = URL(filePath: importArgv[0])
        importer.arguments = Array(importArgv.dropFirst())
        importer.environment = ServiceSpec.baseEnvironment()
        importer.standardInput = importIn
        importer.standardOutput = importOutHandle
        importer.standardError = importOutHandle
        let dumper = Process()
        dumper.executableURL = URL(filePath: dumpArgv[0])
        dumper.arguments = Array(dumpArgv.dropFirst())
        dumper.environment = ServiceSpec.baseEnvironment()
        dumper.standardInput = FileHandle.nullDevice
        dumper.standardOutput = dumpOut
        dumper.standardError = dumpErrHandle

        try importer.run()
        do { try dumper.run() } catch {
            try? importIn.fileHandleForWriting.close()
            importer.terminate()
            importer.waitUntilExit()
            throw error
        }
        // Our copies of the child ends must be closed, otherwise EOF never arrives.
        try? dumpOut.fileHandleForWriting.close()
        try? importIn.fileHandleForReading.close()

        var filter = DefinerStreamFilter()
        var cancelled = false
        var writeFailed = false
        let reader = dumpOut.fileHandleForReading
        let writer = importIn.fileHandleForWriting
        while true {
            if cancel.isCancelled {
                cancelled = true
                break
            }
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if !writeFailed {
                do { try writer.write(contentsOf: filter.feed(chunk)) } catch { writeFailed = true }
            }
        }
        if !cancelled, !writeFailed { try? writer.write(contentsOf: filter.finish()) }
        try? writer.close()
        if cancelled {
            dumper.terminate()
            importer.terminate()
        }
        try? reader.close()
        dumper.waitUntilExit()
        importer.waitUntilExit()
        let tail = { (url: URL) -> String in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").suffix(20).joined(separator: "\n")
        }
        return PipeResult(dumpStatus: dumper.terminationStatus, importStatus: importer.terminationStatus,
                          dumpOutput: tail(dumpErr), importOutput: tail(importOut), cancelled: cancelled)
    }
}
