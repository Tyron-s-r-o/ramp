import Foundation

public enum MySQLBootstrapError: Error, LocalizedError, Equatable {
    /// Datadir has files but ramp.json says it was never initialized — RAMP never re-initializes (data loss).
    case datadirNotEmpty(String)
    case configMissing(String)
    /// `mysqld --initialize-insecure` failed; carries the tail of the error log.
    case initializeFailed(String)
    case startFailed(String)
    /// Setting the root password failed; carries the client output.
    case passwordSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .datadirNotEmpty(let dir):
            return "MySQL data directory \(dir) is not empty but RAMP has no record of initializing it. "
                + "RAMP will not re-initialize it (that would destroy data). Move it away to start fresh, "
                + "or set mysql.initialized = true in ramp.json if it is a valid datadir."
        case .configMissing(let path): return "MySQL config \(path) is missing (render configs first)."
        case .initializeFailed(let tail): return "MySQL datadir initialization failed:\n\(tail)"
        case .startFailed(let reason): return "MySQL did not start after initialization: \(reason)"
        case .passwordSetupFailed(let out): return "Setting the MySQL root password failed:\n\(out)"
        }
    }
}

/// One-time MySQL datadir bootstrap: `--initialize-insecure` → start → set root password for
/// root@localhost / root@127.0.0.1 / root@::1 → `mysql.initialized = true`.
/// The password travels only via stdin (SQL) and a 0600 client defaults file never containing it.
public struct MySQLBootstrapper: Sendable {
    public let paths: Paths
    public let configStore: ConfigStore

    public init(paths: Paths, configStore: ConfigStore) {
        self.paths = paths
        self.configStore = configStore
    }

    public static func needsBootstrap(_ config: RampConfig) -> Bool {
        config.installed["mysql"]?[config.mysql.branch] != nil && !config.mysql.initialized
    }

    /// SQL string literal body: `'` doubled, `\` escaped (default sql_mode has no NO_BACKSLASH_ESCAPES).
    static func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func passwordSQL(_ password: String) -> String {
        let pw = sqlLiteral(password)
        return """
        ALTER USER 'root'@'localhost' IDENTIFIED BY \(pw);
        CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY \(pw);
        CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY \(pw);
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
        FLUSH PRIVILEGES;

        """
    }

    /// Datadir has at least one entry (hidden files count).
    static func isNonEmptyDirectory(_ url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        else { return false }
        return !items.isEmpty
    }

    /// No-op when already initialized. Leaves mysqld running (started through `supervisor` with `spec`).
    /// - Returns: the updated config.
    @discardableResult
    public func bootstrapIfNeeded(config: RampConfig, supervisor: ServiceSupervisor,
                                  spec: ServiceSpec) async throws -> RampConfig {
        guard Self.needsBootstrap(config) else { return config }
        let branch = config.mysql.branch
        let fm = FileManager.default
        let datadir = paths.mysqlData(major: branch)
        if Self.isNonEmptyDirectory(datadir) {
            throw MySQLBootstrapError.datadirNotEmpty(datadir.path(percentEncoded: false))
        }
        let cnf = paths.mysqlConf(major: branch)
        guard fm.fileExists(atPath: cnf.path(percentEncoded: false)) else {
            throw MySQLBootstrapError.configMissing(cnf.path(percentEncoded: false))
        }
        let current = paths.current(component: "mysql", branch: branch)
        let mysqld = current.appending(path: "bin/mysqld").path(percentEncoded: false)
        let mysql = current.appending(path: "bin/mysql").path(percentEncoded: false)
        let defaultsArg = "--defaults-file=\(ConfigText.path(cnf))"

        // 1. initialize (foreground). mysqld creates the datadir itself; remove it again on failure
        //    (it did not exist / was empty before, so nothing of the user's is lost).
        try? fm.createDirectory(at: datadir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: datadir.path(percentEncoded: false)) { try? fm.removeItem(at: datadir) }
        let initResult = await ProcessRunner.run([mysqld, defaultsArg, "--initialize-insecure"],
                                                 cwd: paths.root, tempDir: paths.tmp)
        if initResult.status != 0 {
            try? fm.removeItem(at: datadir)
            throw MySQLBootstrapError.initializeFailed(
                Self.tail(of: paths.log("mysql\(branch).err"), fallback: initResult.output))
        }

        // 2. start via the supervisor
        let state = await supervisor.start(spec)
        guard state.isRunning else {
            if case .failed(let reason) = state { throw MySQLBootstrapError.startFailed(reason) }
            throw MySQLBootstrapError.startFailed("state \(state)")
        }

        // 3. root password — client defaults file (0600) has user + socket only, SQL on stdin.
        let clientCnf = paths.tmp.appending(path: ".mysql-bootstrap-\(UUID().uuidString).cnf", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: clientCnf) }
        let text = ConfigText(dialect: .backslash, separator: "=", commentPrefix: "#")
        let clientConf = "[client]\nuser=root\nsocket=\(try text.quote(ConfigText.path(paths.mysqlSocket(major: branch))))\n"
        guard fm.createFile(atPath: clientCnf.path(percentEncoded: false), contents: Data(clientConf.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw MySQLBootstrapError.passwordSetupFailed("cannot write temp client config")
        }
        let sql = Self.passwordSQL(config.mysql.rootPassword)
        let result = await ProcessRunner.run(
            [mysql, "--defaults-file=\(ConfigText.path(clientCnf))", "--batch", "--silent"],
            cwd: paths.root, stdin: Data(sql.utf8), tempDir: paths.tmp)
        guard result.status == 0 else {
            throw MySQLBootstrapError.passwordSetupFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 4. record
        return try await configStore.update { $0.mysql.initialized = true }
    }

    static func tail(of url: URL, lines: Int = 20, fallback: String) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let source = text.isEmpty ? fallback : text
        return source.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
