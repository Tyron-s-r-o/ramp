import Darwin
import Foundation

/// Identity of a supervised service. `name` is stable and used for log / pid file names.
public enum ServiceID: Hashable, Sendable, CustomStringConvertible {
    case apache
    case phpFPM(String)
    case mysql(String)
    case redis
    /// Optional service (plan 06-01): never autostarts, see `ServiceSpecFactory.elasticsearch`.
    case elasticsearch
    /// Anything else (tests, future helpers). `name` is used verbatim.
    case custom(String)

    /// `apache`, `php8.3-fpm`, `mysql9.7`, `redis`.
    public var name: String {
        switch self {
        case .apache: return "apache"
        case .phpFPM(let b): return "php\(b)-fpm"
        case .mysql(let b): return "mysql\(b)"
        case .redis: return "redis"
        case .elasticsearch: return "elasticsearch"
        case .custom(let n): return n
        }
    }

    /// Human name for messages ("Apache", "PHP 8.3 FPM", …).
    public var displayName: String {
        switch self {
        case .apache: return "Apache"
        case .phpFPM(let b): return "PHP \(b) FPM"
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        case .elasticsearch: return "Elasticsearch"
        case .custom(let n): return n
        }
    }

    public var description: String { name }
}

/// How the supervisor decides a freshly spawned service is ready.
public indirect enum Readiness: Sendable, Equatable {
    case none
    case tcp(host: String, port: Int)
    case unixSocket(URL)
    /// Every check must pass (e.g. MySQL: socket, then TCP).
    case all([Readiness])

    /// One non-blocking-ish probe (loopback connects fail immediately).
    public func isReady() -> Bool {
        switch self {
        case .none: return true
        case .tcp(let host, let port): return SocketAddress.canConnectTCP(host: host, port: port)
        case .unixSocket(let url): return SocketAddress.canConnectUnix(path: url.path(percentEncoded: false))
        case .all(let checks): return checks.allSatisfy { $0.isReady() }
        }
    }

    var unixSockets: [URL] {
        switch self {
        case .unixSocket(let url): return [url]
        case .all(let checks): return checks.flatMap(\.unixSockets)
        default: return []
        }
    }
}

/// Everything needed to run one service as a plain child process (no shell, no daemonizing).
public struct ServiceSpec: Sendable, Equatable {
    public var id: ServiceID
    public var executable: URL
    public var arguments: [String]
    /// Extra environment merged onto `ServiceSpec.baseEnvironment()`.
    public var environment: [String: String]
    public var workingDirectory: URL?
    /// TCP ports the service listens on (probed before start).
    public var ports: [Int]
    /// Addresses the ports are bound on (probe targets).
    public var listenAddresses: [String]
    public var readiness: Readiness
    public var readinessTimeout: Duration
    public var stopSignal: Int32
    /// After `stopSignal`, wait this long, then SIGKILL.
    public var stopTimeout: Duration
    /// Graceful reload signal (httpd SIGUSR1, php-fpm SIGUSR2). nil = not reloadable.
    public var reloadSignal: Int32?
    public var dependsOn: [ServiceID]
    /// Config-test commands run before spawn (argv, first element = executable). Non-zero → failed.
    public var preflight: [[String]]
    /// Needs a one-time bootstrap (MySQL datadir) before it may be started (02-05).
    public var requiresBootstrap: Bool
    /// Variables removed from the resolved environment even if the base has them
    /// (Elasticsearch: `JAVA_HOME`, `ES_JAVA_HOME`, `ES_JAVA_OPTS` — bundled JDK, RAMP-owned heap).
    public var unsetEnvironment: [String]

    public init(id: ServiceID, executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                workingDirectory: URL? = nil, ports: [Int] = [], listenAddresses: [String] = ["127.0.0.1"],
                readiness: Readiness = .none, readinessTimeout: Duration = .seconds(15),
                stopSignal: Int32 = SIGTERM, stopTimeout: Duration = .seconds(10), reloadSignal: Int32? = nil,
                dependsOn: [ServiceID] = [], preflight: [[String]] = [], requiresBootstrap: Bool = false,
                unsetEnvironment: [String] = []) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.listenAddresses = listenAddresses
        self.readiness = readiness
        self.readinessTimeout = readinessTimeout
        self.stopSignal = stopSignal
        self.stopTimeout = stopTimeout
        self.reloadSignal = reloadSignal
        self.dependsOn = dependsOn
        self.preflight = preflight
        self.requiresBootstrap = requiresBootstrap
        self.unsetEnvironment = unsetEnvironment
    }

    /// Minimal clean environment: fixed PATH plus HOME, USER, TMPDIR, LANG from the app.
    public static func baseEnvironment(
        from env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": env["LANG"] ?? "en_US.UTF-8"]
        for key in ["HOME", "USER", "TMPDIR"] { if let v = env[key] { result[key] = v } }
        return result
    }

    /// `baseEnvironment()` with `environment` applied on top, minus `unsetEnvironment`.
    public func resolvedEnvironment(base: [String: String] = ServiceSpec.baseEnvironment()) -> [String: String] {
        var env = base.merging(environment) { _, new in new }
        for key in unsetEnvironment { env[key] = nil }
        return env
    }
}
