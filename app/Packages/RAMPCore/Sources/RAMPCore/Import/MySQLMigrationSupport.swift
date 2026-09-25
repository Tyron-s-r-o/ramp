import Darwin
import Foundation

// Shared helpers of the MAMP MySQL migration (plan 07-04): auth-plugin planning (ISS-004), mysql client with a
// 0600 credentials file (passwords never in argv / logs), source-in-use probe, schema dir name decoding.

/// Authentication plugin an account ends up with after the migration.
public enum MySQLAuthPlugin: String, Codable, Sendable, CaseIterable {
    /// MySQL 8.4/9.x default. PHP ≥ 7.4 mysqlnd supports it; PHP 7.3 does not (ISS-004).
    case cachingSHA2 = "caching_sha2_password"
    /// Still active in 9.7 (deprecated); works with PHP 7.3 mysqlnd. Opt-in only: MAMP 7.3 projects are
    /// imported onto PHP 7.4, which handles caching_sha2_password (ISS-004 resolved).
    case sha256 = "sha256_password"
    /// Only possible when the final server is 8.4 (`mysql-native-password=ON`); removed in 9.x.
    case native = "mysql_native_password"
}

public struct MySQLAccount: Codable, Sendable, Hashable, CustomStringConvertible {
    public var user: String
    public var host: String
    public var plugin: String

    public init(user: String, host: String, plugin: String) {
        self.user = user
        self.host = host
        self.plugin = plugin
    }

    public var description: String { "'\(user)'@'\(host)'" }
    public var key: String { "\(user)@\(host)" }
}

/// Per-account wish of the user: target plugin (+ the account's password, required to re-hash it).
/// `plugin == .native` without password = keep the account as is (final server 8.4 only).
public struct AccountAuthRequest: Sendable, Equatable {
    public var user: String
    public var host: String
    public var plugin: MySQLAuthPlugin
    public var password: String?

    public init(user: String, host: String, plugin: MySQLAuthPlugin, password: String? = nil) {
        self.user = user
        self.host = host
        self.plugin = plugin
        self.password = password
    }

    /// Parses `user@host=plugin` (`plugin` = raw value or `caching_sha2` / `sha256` / `native`).
    public static func parse(_ text: String) -> AccountAuthRequest? {
        guard let eq = text.lastIndex(of: "="), let at = text[..<eq].lastIndex(of: "@") else { return nil }
        let user = String(text[..<at]), host = String(text[text.index(after: at)..<eq])
        let raw = String(text[text.index(after: eq)...])
        guard !user.isEmpty, !host.isEmpty, let plugin = MySQLAuthPlugin.parse(raw) else { return nil }
        return AccountAuthRequest(user: user, host: host, plugin: plugin)
    }
}

extension MySQLAuthPlugin {
    public static func parse(_ raw: String) -> MySQLAuthPlugin? {
        switch raw.lowercased() {
        case "caching_sha2_password", "caching_sha2", "caching-sha2": .cachingSHA2
        case "sha256_password", "sha256": .sha256
        case "mysql_native_password", "native": .native
        default: nil
        }
    }
}

public struct AccountConversion: Sendable, Equatable {
    public var account: MySQLAccount
    public var plugin: MySQLAuthPlugin
    /// In memory only — never persisted or logged.
    public var password: String
}

/// Outcome of the users step (persisted without passwords).
public struct AccountAuthPlan: Sendable, Equatable {
    public var conversions: [AccountConversion] = []
    public var keptNative: [MySQLAccount] = []
    /// `mysql_native_password` accounts that will not be able to log in on 9.x.
    public var unconverted: [MySQLAccount] = []
}

public enum AccountAuthPlanError: Error, LocalizedError, Equatable {
    case unknownAccount(String)
    case passwordRequired(String)
    case nativeRequires84(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAccount(let a): "Account \(a) does not exist in the migrated datadir."
        case .passwordRequired(let a): "Converting \(a) needs its password (the old hash cannot be converted)."
        case .nativeRequires84(let a):
            "\(a) can keep mysql_native_password only when the migration stops at MySQL 8.4 (removed in 9.x)."
        }
    }
}

/// Decides per account what the users step does (pure; ISS-004: target plugin per account, default
/// caching_sha2_password — the final policy is the user's choice, nothing is hard-coded beyond the default).
public enum AccountAuthPlanner {
    public static let rootHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public static func plan(accounts: [MySQLAccount], requests: [AccountAuthRequest], rootPassword: String,
                            rootPlugin: MySQLAuthPlugin = .cachingSHA2,
                            targetBranch: String) throws(AccountAuthPlanError) -> AccountAuthPlan {
        var result = AccountAuthPlan()
        let byKey = Dictionary(accounts.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var handled = Set<String>()
        let keeps84 = targetBranch == "8.4"
        for request in requests {
            let key = "\(request.user)@\(request.host)"
            guard let account = byKey[key] else { throw .unknownAccount("'\(request.user)'@'\(request.host)'") }
            handled.insert(key)
            if request.plugin == .native {
                guard keeps84 else { throw .nativeRequires84(account.description) }
                if let pw = request.password {
                    result.conversions.append(AccountConversion(account: account, plugin: .native, password: pw))
                } else if account.plugin == MySQLAuthPlugin.native.rawValue {
                    result.keptNative.append(account)
                } else {
                    throw .passwordRequired(account.description)
                }
                continue
            }
            let isRoot = account.user == "root" && rootHosts.contains(account.host)
            guard let pw = request.password ?? (isRoot ? rootPassword : nil) else {
                throw .passwordRequired(account.description)
            }
            result.conversions.append(AccountConversion(account: account, plugin: request.plugin, password: pw))
        }
        for account in accounts.sorted(by: { $0.key < $1.key }) where !handled.contains(account.key) {
            if account.user == "root", rootHosts.contains(account.host) {
                if account.plugin == MySQLAuthPlugin.native.rawValue || rootPlugin.rawValue != account.plugin {
                    result.conversions.append(AccountConversion(account: account, plugin: rootPlugin, password: rootPassword))
                }
            } else if account.plugin == MySQLAuthPlugin.native.rawValue {
                if keeps84 { result.keptNative.append(account) } else { result.unconverted.append(account) }
            }
        }
        return result
    }

    /// SQL for the conversions + RAMP's root@127.0.0.1 / root@::1 (created when missing, as MySQLBootstrapper does).
    static func sql(_ plan: AccountAuthPlan, rootPassword: String, rootPlugin: MySQLAuthPlugin) -> String {
        var lines: [String] = []
        for c in plan.conversions {
            lines.append("ALTER USER \(SQL.literal(c.account.user))@\(SQL.literal(c.account.host)) "
                         + "IDENTIFIED WITH \(c.plugin.rawValue) BY \(SQL.literal(c.password));")
        }
        for host in ["127.0.0.1", "::1"] {
            lines.append("CREATE USER IF NOT EXISTS 'root'@\(SQL.literal(host)) "
                         + "IDENTIFIED WITH \(rootPlugin.rawValue) BY \(SQL.literal(rootPassword));")
            lines.append("GRANT ALL PRIVILEGES ON *.* TO 'root'@\(SQL.literal(host)) WITH GRANT OPTION;")
        }
        lines.append("FLUSH PRIVILEGES;")
        return lines.joined(separator: "\n") + "\n"
    }
}

enum SQL {
    /// String literal: `'` doubled, `\` escaped.
    static func literal(_ value: String) -> String { MySQLBootstrapper.sqlLiteral(value) }
    /// Backtick identifier.
    static func identifier(_ name: String) -> String { "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }
}

/// MySQL on-disk name decoding (`app@002dtwo` → `app-two`): `@XXXX` hex code points; other `@` forms kept.
public enum MySQLFilename {
    public static func decode(_ name: String) -> String {
        var out = ""
        var chars = Substring(name)
        while let at = chars.firstIndex(of: "@") {
            out += chars[..<at]
            let hex = chars[chars.index(after: at)...].prefix(4)
            if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                out.unicodeScalars.append(scalar)
                chars = chars[chars.index(at, offsetBy: 5)...]
            } else {
                out += "@"
                chars = chars[chars.index(after: at)...]
            }
        }
        return out + chars
    }
}

public enum MySQLClientError: Error, LocalizedError, Equatable {
    case failed(String)
    case accessDenied(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let m): "mysql client failed: \(m)"
        case .accessDenied(let m): "MySQL rejected the credentials: \(m)"
        }
    }
}

/// 0600 `[client]` option file (user, password, socket) used as `--defaults-file` — the password never
/// appears in argv or the environment. Caller deletes it (`remove()`).
struct MySQLCredentialsFile {
    let url: URL

    /// `plugin-dir` next to a client binary (`<basedir>/bin/mysql` → `<basedir>/lib/plugin`): the 9.x client
    /// loads `mysql_native_password` (needed for MAMP 8.0 accounts) from there, not from its compiled-in path.
    static func pluginDir(forBinary binary: URL) -> URL? {
        let dir = binary.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "lib/plugin", directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
            ? dir : nil
    }

    init(directory: URL, user: String, password: String, socket: URL?, pluginDir: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appending(path: ".client-\(UUID().uuidString).cnf", directoryHint: .notDirectory)
        let t = ConfigText(dialect: .backslash, separator: "=", commentPrefix: "#")
        var text = "[client]\nuser=\(try t.quote(user, key: "user"))\npassword=\(try t.quote(password, key: "password"))\n"
        if let socket { text += "socket=\(try t.quote(ConfigText.path(socket), key: "socket"))\n" }
        if let pluginDir { text += "plugin-dir=\(try t.quote(ConfigText.path(pluginDir), key: "plugin-dir"))\n" }
        guard fm.createFile(atPath: url.path(percentEncoded: false), contents: Data(text.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw MySQLClientError.failed("cannot write credentials file in \(directory.path(percentEncoded: false))")
        }
    }

    var argument: String { "--defaults-file=\(ConfigText.path(url))" }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// `bin/mysql` over a unix socket, SQL on stdin, batch output.
struct MySQLClient: Sendable {
    var binary: URL
    var socket: URL
    var user: String
    var password: String
    var tempDir: URL

    func execute(_ sql: String, database: String? = nil) async throws(MySQLClientError) -> String {
        let creds: MySQLCredentialsFile
        do {
            creds = try MySQLCredentialsFile(directory: tempDir, user: user, password: password, socket: socket,
                                             pluginDir: MySQLCredentialsFile.pluginDir(forBinary: binary))
        } catch {
            throw .failed(error.localizedDescription)
        }
        defer { creds.remove() }
        var argv = [binary.path(percentEncoded: false), creds.argument, "--batch", "--skip-column-names",
                    "--default-character-set=utf8mb4"]
        if let database { argv.append(database) }
        let result = await ProcessRunner.run(argv, stdin: Data(sql.utf8), tempDir: tempDir)
        guard result.status == 0 else {
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("ERROR 1045") || text.contains("ERROR 1524") || text.contains("ERROR 2059") {
                throw .accessDenied(text)
            }
            throw .failed(text.isEmpty ? "exit \(result.status)" : text)
        }
        return result.output
    }

    func rows(_ sql: String, database: String? = nil) async throws(MySQLClientError) -> [[String]] {
        Self.parseBatch(try await execute(sql, database: database))
    }

    /// `--batch` output: tab-separated, `\t` `\n` `\\` `\0` escaped.
    static func parseBatch(_ text: String) -> [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
        }
    }

    static func unescape(_ field: String) -> String {
        guard field.contains("\\") else { return field }
        var out = ""
        var escaping = false
        for ch in field {
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
        return out
    }
}

/// Is a mysqld using the source datadir? (plan 07-04: method (a) refuses, method (b) requires it.)
public struct SourceUsage: Sendable, Equatable {
    public var reasons: [String] = []
    public var inUse: Bool { !reasons.isEmpty }
}

public enum SourceUsageProbe {
    /// MAMP PRO's defaults (DISCOVERY §2b).
    public static let mampDatadir = URL(filePath: "/Library/Application Support/appsolute/MAMP PRO/db/mysql80",
                                        directoryHint: .isDirectory)
    public static let mampSocket = URL(filePath: "/Applications/MAMP/tmp/mysql/mysql.sock", directoryHint: .notDirectory)
    public static let mampBin = URL(filePath: "/Applications/MAMP/Library/bin/mysql80/bin", directoryHint: .isDirectory)

    /// Read-only checks: fcntl write lock on `ibdata1` (InnoDB holds it while running), a `mysqld` process
    /// whose command line names the datadir, and connectable sockets.
    public static func check(datadir: URL, sockets: [URL]) -> SourceUsage {
        var usage = SourceUsage()
        let dir = datadir.standardizedFileURL.path(percentEncoded: false)
        if let pid = lockHolder(dir + (dir.hasSuffix("/") ? "" : "/") + "ibdata1") {
            usage.reasons.append("ibdata1 is locked by process \(pid) (a mysqld is running on this datadir)")
        }
        for (pid, command) in mysqldProcesses(naming: datadir) {
            usage.reasons.append("mysqld pid \(pid) uses the datadir: \(command.prefix(160))")
        }
        for socket in sockets where SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false)) {
            usage.reasons.append("socket \(socket.path(percentEncoded: false)) accepts connections")
        }
        return usage
    }

    /// Default sockets that count as "source in use": MAMP's socket only when `datadir` is MAMP's datadir.
    public static func defaultSockets(for datadir: URL) -> [URL] {
        let a = datadir.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let b = mampDatadir.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return a.trimmingSuffix("/") == b.trimmingSuffix("/") ? [mampSocket] : []
    }

    /// PID holding a conflicting fcntl lock on `path` (opened O_RDONLY, nothing is locked by us).
    static func lockHolder(_ path: String) -> pid_t? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        guard fcntl(fd, F_GETLK, &fl) == 0, fl.l_type != Int16(F_UNLCK) else { return nil }
        return fl.l_pid
    }

    /// `ps` rows of mysqld processes whose argv contains the datadir path (both /tmp spellings).
    static func mysqldProcesses(naming datadir: URL) -> [(pid_t, String)] {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return matching(psOutput: String(decoding: data, as: UTF8.self), datadir: datadir)
    }

    static func matching(psOutput: String, datadir: URL) -> [(pid_t, String)] {
        let std = datadir.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let resolved = datadir.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/")
        var spellings = Set([std, resolved])
        for s in Array(spellings) {
            if s.hasPrefix("/private/") { spellings.insert(String(s.dropFirst("/private".count))) }
            else if s.hasPrefix("/tmp/") || s.hasPrefix("/var/") { spellings.insert("/private" + s) }
        }
        var result: [(pid_t, String)] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            guard let exe = command.split(separator: " ").first, exe.hasSuffix("mysqld") else { continue }
            if spellings.contains(where: { s in
                command.contains("--datadir=\(s) ") || command.hasSuffix("--datadir=\(s)")
                    || command.contains("--datadir=\(s)/ ") || command.hasSuffix("--datadir=\(s)/")
            }) {
                result.append((pid, command))
            }
        }
        return result
    }
}

fileprivate extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.count > 1 && s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
