import Foundation

/// Errors raised by `Paths`.
public enum PathsError: Error, Equatable, CustomStringConvertible {
    /// A unix-domain socket path exceeds the `sun_path` limit (104 bytes incl. NUL on macOS).
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path):
            return "Unix socket path is \(path.utf8.count) bytes, but macOS allows at most "
                + "\(Paths.maxSocketPathBytes - 1) (sun_path limit \(Paths.maxSocketPathBytes)): \(path)"
        }
    }
}

/// On-disk layout of everything RAMP owns. Every component obtains paths only via this type.
///
/// ```
/// <root>/ramp.json                      single source of truth (+ ramp.json.bak)
/// <root>/<component>/<version>/         extracted package (php/8.3.35, apache/2.4.68, …)
/// <root>/<component>/<branch>/current   relative symlink -> ../<version>
/// <root>/conf/apache/httpd.conf         generated (conf/apache/vhosts/ reserved for Phase 3)
/// <root>/conf/php/<branch>/{php.ini,php-cli.ini,php-fpm.conf,conf.d/}
/// <root>/composer/composer.phar         Composer for the terminal shims (~/.ramp/bin, `ShellIntegration`)
/// <root>/conf/mysql/<major>/my.cnf
/// <root>/conf/redis/redis.conf
/// <root>/conf/elasticsearch/{elasticsearch.yml,jvm.options.d/}   ES_PATH_CONF (optional service)
/// <root>/run/                           sockets + pid files (php8.3.sock, mysql9.7.sock, httpd.pid,
///                                       supervisor/<service>.pid)
/// <root>/mysql-data/<major>/            MySQL datadir
/// <root>/redis-data/
/// <root>/elasticsearch-data/<branch>/   <root>/tmp/elasticsearch/   <logs>/elasticsearch/
/// <root>/www/default/index.php          default docroot for http://localhost/
/// <root>/downloads/  <root>/.staging/  <root>/tmp/  <root>/backups/ (automatic MySQL dumps)
/// <logs>/                               all logs (~/Library/Logs/RAMP)
/// ```
///
/// Paths may contain spaces ("Application Support"); every consumer must quote them.
public struct Paths: Sendable, Equatable {
    /// `sun_path` size on macOS (including the terminating NUL).
    public static let maxSocketPathBytes = 104

    public let root: URL
    public let logs: URL

    public init(root: URL, logs: URL) {
        self.root = root.standardizedFileURL
        self.logs = logs.standardizedFileURL
    }

    /// Standard layout: `~/Library/Application Support/RAMP` + `~/Library/Logs/RAMP`.
    /// Overridable via environment `RAMP_HOME` / `RAMP_LOGS` (dev + integration tests).
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Paths {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        let root = environment["RAMP_HOME"].flatMap(nonEmptyDir)
            ?? library.appending(path: "Application Support/RAMP", directoryHint: .isDirectory)
        let logs = environment["RAMP_LOGS"].flatMap(nonEmptyDir)
            ?? library.appending(path: "Logs/RAMP", directoryHint: .isDirectory)
        return Paths(root: root, logs: logs)
    }

    private static func nonEmptyDir(_ path: String) -> URL? {
        path.isEmpty ? nil : URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    private func dir(_ components: String...) -> URL {
        components.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    // MARK: Config file

    public var configFile: URL { root.appending(path: "ramp.json", directoryHint: .notDirectory) }
    public var configBackup: URL { root.appending(path: "ramp.json.bak", directoryHint: .notDirectory) }

    // MARK: Packages

    /// Extracted package directory, e.g. `<root>/php/8.3.35`.
    public func package(component: String, version: String) -> URL { dir(component, version) }

    /// Branch directory holding the `current` symlink, e.g. `<root>/php/8.3`.
    public func branchDir(component: String, branch: String) -> URL { dir(component, branch) }

    /// `current` symlink, e.g. `<root>/php/8.3/current` -> `../8.3.35`.
    public func current(component: String, branch: String) -> URL {
        branchDir(component: component, branch: branch).appending(path: "current", directoryHint: .notDirectory)
    }

    // MARK: Generated configuration

    public var confDir: URL { dir("conf") }
    public var apacheConfDir: URL { dir("conf", "apache") }
    public var apacheVhostsDir: URL { dir("conf", "apache", "vhosts") }
    public var apacheConf: URL { apacheConfDir.appending(path: "httpd.conf", directoryHint: .notDirectory) }

    public func phpConfDir(branch: String) -> URL { dir("conf", "php", branch) }
    public func phpConfD(branch: String) -> URL { dir("conf", "php", branch, "conf.d") }
    public func phpIni(branch: String) -> URL {
        phpConfDir(branch: branch).appending(path: "php.ini", directoryHint: .notDirectory)
    }
    public func fpmConf(branch: String) -> URL {
        phpConfDir(branch: branch).appending(path: "php-fpm.conf", directoryHint: .notDirectory)
    }
    /// php.ini for the terminal (`~/.ramp/bin/php<branch>` shims): the FPM php.ini plus CLI tweaks.
    public func phpCliIni(branch: String) -> URL {
        phpConfDir(branch: branch).appending(path: Self.phpCliIniName, directoryHint: .notDirectory)
    }
    public static let phpCliIniName = "php-cli.ini"

    // MARK: Composer (terminal integration)

    /// `<root>/composer/composer.phar` — Composer 2 stable, run by the `composer` shim.
    public var composerDir: URL { dir("composer") }
    public var composerPhar: URL { composerDir.appending(path: "composer.phar", directoryHint: .notDirectory) }

    public func mysqlConfDir(major: String) -> URL { dir("conf", "mysql", major) }
    public func mysqlConf(major: String) -> URL {
        mysqlConfDir(major: major).appending(path: "my.cnf", directoryHint: .notDirectory)
    }

    public var redisConfDir: URL { dir("conf", "redis") }
    public var redisConf: URL { redisConfDir.appending(path: "redis.conf", directoryHint: .notDirectory) }

    /// `ES_PATH_CONF`, e.g. `<root>/conf/elasticsearch` (elasticsearch.yml + package base config).
    public var elasticsearchConfDir: URL { dir("conf", "elasticsearch") }
    public var elasticsearchConf: URL {
        elasticsearchConfDir.appending(path: "elasticsearch.yml", directoryHint: .notDirectory)
    }
    public var elasticsearchJvmOptionsDir: URL { dir("conf", "elasticsearch", "jvm.options.d") }

    // MARK: Runtime (sockets, pids)

    public var runDir: URL { dir("run") }
    public var supervisorRunDir: URL { dir("run", "supervisor") }
    /// PHP-FPM socket, e.g. `<root>/run/php8.3.sock`.
    public func fpmSocket(branch: String) -> URL {
        runDir.appending(path: "php\(branch).sock", directoryHint: .notDirectory)
    }
    /// MySQL socket, e.g. `<root>/run/mysql9.7.sock`.
    public func mysqlSocket(major: String) -> URL {
        runDir.appending(path: "mysql\(major).sock", directoryHint: .notDirectory)
    }
    /// Apache's own pid file (`PidFile` directive).
    public var httpdPidFile: URL { runDir.appending(path: "httpd.pid", directoryHint: .notDirectory) }
    /// Supervisor-owned pid file, e.g. `<root>/run/supervisor/mysql.pid`.
    public func pidFile(service: String) -> URL {
        supervisorRunDir.appending(path: "\(service).pid", directoryHint: .notDirectory)
    }

    // MARK: Data

    public func mysqlData(major: String) -> URL { dir("mysql-data", major) }
    public var redisData: URL { dir("redis-data") }
    public var defaultDocroot: URL { dir("www", "default") }
    /// Elasticsearch `path.data`, e.g. `<root>/elasticsearch-data/9.5`.
    public func elasticsearchData(branch: String) -> URL { dir("elasticsearch-data", branch) }

    // MARK: Scratch

    public var downloads: URL { dir("downloads") }
    public var staging: URL { dir(".staging") }
    public var tmp: URL { dir("tmp") }
    /// Automatic MySQL dumps before updates (plan 07-02), e.g. `<root>/backups/mysql-9.7-20260925-120000.sql`.
    public var backups: URL { dir("backups") }
    /// `ES_TMPDIR`.
    public var elasticsearchTmp: URL { dir("tmp", "elasticsearch") }

    // MARK: Logs

    /// Log file under `logs`, e.g. `log("apache-error.log")`.
    public func log(_ name: String) -> URL { logs.appending(path: name, directoryHint: .notDirectory) }
    /// Elasticsearch `path.logs` (subdir: ES writes its own `elasticsearch.log`, which would collide with
    /// the supervisor's `<logs>/elasticsearch.log`).
    public var elasticsearchLogs: URL { logs.appending(path: "elasticsearch", directoryHint: .isDirectory) }

    // MARK: Filesystem

    /// Creates every static directory of the layout (0755; `run/` and `run/supervisor/` 0700).
    /// Branch/version specific directories are created by the components that own them.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        let normal: [URL] = [
            root, logs, confDir, apacheConfDir, apacheVhostsDir, dir("conf", "php"), dir("conf", "mysql"),
            redisConfDir, dir("mysql-data"), redisData, defaultDocroot, downloads, staging, tmp,
        ]
        for url in normal {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
        }
        for url in [runDir, supervisorRunDir] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Enforce even if the directory pre-existed with other permissions.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// Throws `PathsError.socketPathTooLong` if `url` cannot be bound as a unix socket.
    public func validateSocketPath(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        if path.utf8.count >= Self.maxSocketPathBytes {
            throw PathsError.socketPathTooLong(path)
        }
    }
}
