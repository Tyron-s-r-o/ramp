import Foundation

public struct HealthResult: Sendable, Equatable {
    public var ok: Bool
    public var detail: String

    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }

    public static func pass(_ detail: String) -> Self { Self(ok: true, detail: detail) }
    public static func fail(_ detail: String) -> Self { Self(ok: false, detail: detail) }
}

/// Post-update health check of one component/branch (tests inject a fake).
public protocol HealthProbing: Sendable {
    /// - Parameter serviceRunning: the affected service is (supposed to be) running; `false` → only offline
    ///   checks (`-t` / `--version` / file present), nothing is contacted.
    func check(component: String, branch: String, config: RampConfig, serviceRunning: Bool) async -> HealthResult
}

/// HTTP status of a local URL (injectable).
public protocol HTTPStatusFetching: Sendable {
    func status(of url: URL, timeout: TimeInterval) async throws -> Int
}

public struct URLSessionStatusFetcher: HTTPStatusFetching {
    public init() {}

    public func status(of url: URL, timeout: TimeInterval) async throws -> Int {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.connectionProxyDictionary = [:]   // never through a system proxy
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Component health checks (plan 07-02):
/// - apache: `httpd -t`, then GET `http://127.0.0.1:<port>/` < 500
/// - php: `php-fpm -t` with the generated config + FPM socket accepts + the branch CLI's `php -v`
/// - mysql: `SELECT VERSION()` via the socket (stopped: `mysqld --version`)
/// - redis: `PING` → PONG (stopped: `redis-server --version`)
/// - phpmyadmin: GET `/phpmyadmin/` < 500 when Apache runs, else `index.php` present
/// - elasticsearch: GET `http://127.0.0.1:<http port>/` == 200 (stopped: package sanity only)
/// - elasticvue: GET `/elasticvue/` == 200 when Apache runs and Elasticsearch is installed, else `index.html` present
public struct HealthProbe: HealthProbing {
    public static let httpTimeout: TimeInterval = 5
    public static let toolTimeout: Duration = .seconds(30)

    public let paths: Paths
    private let runner: any ProcessRunning
    private let http: any HTTPStatusFetching

    public init(paths: Paths, runner: (any ProcessRunning)? = nil, http: (any HTTPStatusFetching)? = nil) {
        self.paths = paths
        self.runner = runner ?? SystemProcessRunner(tempDir: paths.tmp)
        self.http = http ?? URLSessionStatusFetcher()
    }

    public func check(component: String, branch: String, config: RampConfig,
                      serviceRunning: Bool) async -> HealthResult {
        let current = paths.current(component: component, branch: branch)
        switch component {
        case "apache": return await apache(config: config, running: serviceRunning)
        case "php": return await php(branch: branch, config: config, running: serviceRunning)
        case "mysql": return await mysql(branch: branch, config: config, running: serviceRunning)
        case "redis": return await redis(current: current, config: config, running: serviceRunning)
        case "phpmyadmin": return await phpMyAdmin(current: current, config: config)
        case "elasticsearch": return await elasticsearch(current: current, config: config, running: serviceRunning)
        case "elasticvue": return await elasticvue(current: current, config: config)
        default: return .fail("no health check for \(component)")
        }
    }

    // MARK: Components

    private func apache(config: RampConfig, running: Bool) async -> HealthResult {
        guard let spec = try? ServiceSpecFactory.specs(config: config, paths: paths).first(where: { $0.id == .apache })
        else { return .fail("Apache is not configured") }
        for argv in spec.preflight {
            let r = await runner.run(argv, environment: spec.resolvedEnvironment(), timeout: Self.toolTimeout)
            guard r.status == 0 else { return .fail("httpd -t: \(Self.trim(r.output))") }
        }
        guard running else { return .pass("httpd -t OK") }
        let host = ServiceSpecFactory.connectHost(config.apache.listenAddresses.first ?? "127.0.0.1")
        return await httpCheck(host: host, port: config.apache.port, path: "/", accept: { $0 < 500 })
    }

    private func php(branch: String, config: RampConfig, running: Bool) async -> HealthResult {
        let current = paths.current(component: "php", branch: branch)
        var notes: [String] = []
        if FileManager.default.fileExists(atPath: paths.fpmConf(branch: branch).path(percentEncoded: false)),
           let spec = try? ServiceSpecFactory.phpFPM(branch: branch, config: config, paths: paths) {
            for argv in spec.preflight {
                let r = await runner.run(argv, environment: spec.resolvedEnvironment(), timeout: Self.toolTimeout)
                guard r.status == 0 else { return .fail("php-fpm -t: \(Self.trim(r.output))") }
            }
            notes.append("php-fpm -t OK")
        } else {
            let fpm = current.appending(path: "sbin/php-fpm").path(percentEncoded: false)
            let r = await runner.run([fpm, "-v"], environment: ServiceSpec.baseEnvironment(), timeout: Self.toolTimeout)
            guard r.status == 0 else { return .fail("php-fpm -v: \(Self.trim(r.output))") }
            notes.append("php-fpm -v OK")
        }
        if running {
            guard SocketAddress.canConnectUnix(path: paths.fpmSocket(branch: branch).path(percentEncoded: false)) else {
                return .fail("PHP-FPM \(branch) socket does not accept connections")
            }
            notes.append("socket OK")
        }
        let cli = current.appending(path: "bin/php").path(percentEncoded: false)
        if FileManager.default.isExecutableFile(atPath: cli) {
            let r = await runner.run([cli, "-v"], environment: ServiceSpec.baseEnvironment(), timeout: Self.toolTimeout)
            guard r.status == 0 else { return .fail("php -v: \(Self.trim(r.output))") }
            notes.append(Self.firstLine(r.output))
        }
        return .pass(notes.joined(separator: "; "))
    }

    private func mysql(branch: String, config: RampConfig, running: Bool) async -> HealthResult {
        guard running, branch == config.mysql.branch else {
            let mysqld = paths.current(component: "mysql", branch: branch).appending(path: "bin/mysqld")
            let r = await runner.run([mysqld.path(percentEncoded: false), "--version"],
                                     environment: ServiceSpec.baseEnvironment(), timeout: Self.toolTimeout)
            return r.status == 0 ? .pass(Self.firstLine(r.output)) : .fail("mysqld --version: \(Self.trim(r.output))")
        }
        do {
            let version = try await DatabaseInfoService(paths: paths).mysqlVersion(config)
            return version.isEmpty ? .fail("SELECT VERSION() returned nothing") : .pass("MySQL \(version)")
        } catch {
            return .fail("SELECT VERSION(): \(error.localizedDescription)")
        }
    }

    private func redis(current: URL, config: RampConfig, running: Bool) async -> HealthResult {
        guard running else {
            let server = current.appending(path: "bin/redis-server").path(percentEncoded: false)
            let r = await runner.run([server, "--version"], environment: ServiceSpec.baseEnvironment(),
                                     timeout: Self.toolTimeout)
            return r.status == 0 ? .pass(Self.firstLine(r.output)) : .fail("redis-server --version: \(Self.trim(r.output))")
        }
        let cli = current.appending(path: "bin/redis-cli").path(percentEncoded: false)
        let host = ServiceSpecFactory.connectHost(config.redis.bindAddress)
        let r = await runner.run([cli, "-h", host, "-p", String(config.redis.port), "PING"],
                                 environment: ServiceSpec.baseEnvironment(), timeout: Self.toolTimeout)
        let out = Self.trim(r.output)
        return r.status == 0 && out == "PONG" ? .pass("PING → PONG") : .fail("redis PING: \(out)")
    }

    private func phpMyAdmin(current: URL, config: RampConfig) async -> HealthResult {
        guard FileManager.default.fileExists(atPath: current.appending(path: "index.php").path(percentEncoded: false))
        else { return .fail("phpMyAdmin index.php missing") }
        let host = ServiceSpecFactory.connectHost(config.apache.listenAddresses.first ?? "127.0.0.1")
        guard SocketAddress.canConnectTCP(host: host, port: config.apache.port) else {
            return .pass("index.php present (Apache not running, HTTP check skipped)")
        }
        return await httpCheck(host: host, port: config.apache.port, path: "/phpmyadmin/", accept: { $0 < 500 })
    }

    private func elasticvue(current: URL, config: RampConfig) async -> HealthResult {
        guard FileManager.default.fileExists(atPath: current.appending(path: "index.html").path(percentEncoded: false))
        else { return .fail("Elasticvue index.html missing") }
        let host = ServiceSpecFactory.connectHost(config.apache.listenAddresses.first ?? "127.0.0.1")
        guard ElasticvueConfigGenerator(config: config, paths: paths).site() != nil,
              SocketAddress.canConnectTCP(host: host, port: config.apache.port) else {
            return .pass("index.html present (HTTP check skipped)")
        }
        return await httpCheck(host: host, port: config.apache.port,
                               path: ElasticvueConfigGenerator.urlPath + "/", accept: { $0 == 200 })
    }

    private func elasticsearch(current: URL, config: RampConfig, running: Bool) async -> HealthResult {
        guard running else {
            let ok = FileManager.default.isExecutableFile(
                atPath: current.appending(path: "bin/elasticsearch").path(percentEncoded: false))
            return ok ? .pass("package present (not running)") : .fail("bin/elasticsearch missing")
        }
        let host = config.elasticsearch.bindAddress == "::1" ? "::1" : "127.0.0.1"
        return await httpCheck(host: host, port: config.elasticsearch.httpPort, path: "/", accept: { $0 == 200 })
    }

    // MARK: Helpers

    private func httpCheck(host: String, port: Int, path: String, accept: (Int) -> Bool) async -> HealthResult {
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(authority):\(port)\(path)") else { return .fail("bad URL") }
        do {
            let status = try await http.status(of: url, timeout: Self.httpTimeout)
            return accept(status) ? .pass("GET \(path) → \(status)") : .fail("GET \(url.absoluteString) → HTTP \(status)")
        } catch {
            return .fail("GET \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 800 ? String(t.suffix(800)) : t
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
    }
}
