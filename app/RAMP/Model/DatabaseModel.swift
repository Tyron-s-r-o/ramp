import AppKit
import Foundation
import Observation
import RAMPCore

/// State of the Databáza section. Loads on appear and on explicit refresh only (no polling).
@MainActor @Observable
final class DatabaseModel {
    private(set) var mysqlVersion: String?
    private(set) var databases: [DatabaseSize] = []
    private(set) var mysqlError: String?
    private(set) var loadingMySQL = false

    private(set) var redis: RedisInfo?
    private(set) var redisError: String?
    private(set) var loadingRedis = false
    private(set) var flushing = false

    private(set) var esHealth: ElasticsearchClusterHealth?
    private(set) var esIndices: [ElasticsearchIndexInfo] = []
    private(set) var esError: String?
    private(set) var loadingES = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let service: DatabaseInfoService
    /// Native key browser of the Redis tab.
    let redisBrowser = RedisBrowserModel()

    init(paths: Paths) {
        service = DatabaseInfoService(paths: paths)
    }

    var totalBytes: Int64 { databases.reduce(0) { $0 + $1.bytes } }

    private var config: RampConfig { app?.config ?? RampConfig() }

    func state(of id: ServiceID) -> ServiceState {
        app?.services.rows.first { $0.id == id }?.state ?? .stopped
    }

    var mysqlID: ServiceID { .mysql(config.mysql.branch) }

    // MARK: Loading

    func refresh() async {
        async let m: Void = refreshMySQL()
        async let r: Void = refreshRedis()
        async let e: Void = refreshElasticsearch()
        _ = await (m, r, e)
    }

    func refreshMySQL() async {
        #if DEBUG
        if ScreenshotMode.isActive { mysqlVersion = DemoData.mysqlVersion; databases = DemoData.databases; return }
        #endif
        guard state(of: mysqlID).isRunning else {
            mysqlError = String(localized: "MySQL nebeží")
            databases = []
            return
        }
        loadingMySQL = true
        defer { loadingMySQL = false }
        let config = config
        do {
            mysqlVersion = try await service.mysqlVersion(config)
            databases = try await service.mysqlDatabases(config)
            mysqlError = nil
        } catch {
            mysqlError = Self.message(error)
        }
    }

    func refreshRedis() async {
        #if DEBUG
        if ScreenshotMode.isActive { redis = DemoData.redis; return }
        #endif
        guard state(of: .redis).isRunning else {
            redisError = String(localized: "Redis nebeží")
            redis = nil
            return
        }
        loadingRedis = true
        defer { loadingRedis = false }
        do {
            redis = try await service.redisInfo(config)
            redisError = nil
        } catch {
            redisError = Self.message(error)
        }
    }

    /// Cluster health + indices over HTTP (3 s timeout). Not installed / not running → no request.
    func refreshElasticsearch() async {
        #if DEBUG
        if ScreenshotMode.isActive { esHealth = nil; esIndices = []; esError = String(localized: "Elasticsearch nebeží"); return }
        #endif
        guard let es = app?.elasticsearch, es.isInstalled else {
            esHealth = nil
            esIndices = []
            esError = nil
            return
        }
        guard es.state.isRunning else {
            esError = String(localized: "Elasticsearch nebeží")
            esHealth = nil
            esIndices = []
            return
        }
        loadingES = true
        defer { loadingES = false }
        let client = ElasticsearchHTTPClient(baseURL: es.httpURL)
        do {
            async let health = client.clusterHealth()
            async let indices = client.indices()
            let (h, i) = try await (health, indices)
            esHealth = h
            esIndices = i.sorted { $0.index.localizedStandardCompare($1.index) == .orderedAscending }
            esError = nil
        } catch {
            esHealth = nil
            esIndices = []
            esError = Self.message(error)
        }
    }

    var esTotalBytes: Int64 { esIndices.reduce(0) { $0 + ($1.storeBytes ?? 0) } }

    func flushRedis() async {
        flushing = true
        defer { flushing = false }
        do {
            try await service.redisFlushAll(config)
        } catch {
            app?.report(title: String(localized: "FLUSHALL zlyhal"), error: error)
        }
        await refreshRedis()
    }

    // MARK: Start / stop (via the Services model, so rows + health stay in sync)

    func toggle(_ id: ServiceID) async {
        guard let services = app?.services else { return }
        if state(of: id).isRunning {
            await services.stop(id)
        } else {
            await services.start(id)
        }
        switch id {
        case .redis: await refreshRedis()
        case .elasticsearch: await refreshElasticsearch()
        default: await refreshMySQL()
        }
    }

    // MARK: Connection details

    var mysqlHost: String {
        switch config.mysql.bindAddress {
        case "0.0.0.0", "*", "", "127.0.0.1": "127.0.0.1"
        case "::", "[::]": "::1"
        case let other: other
        }
    }

    var mysqlPort: Int { config.mysql.port }
    var redisPort: Int { config.redis.port }

    /// Connect address for the configured Redis bind address (wildcards → loopback).
    var redisHost: String {
        switch config.redis.bindAddress {
        case "0.0.0.0", "*", "": "127.0.0.1"
        case "::", "[::]": "::1"
        case let other: other
        }
    }
    var rootPassword: String { config.mysql.rootPassword }

    var mysqlSocket: String {
        #if DEBUG
        if ScreenshotMode.isActive { return "~/Library/Application Support/RAMP/run/mysql\(config.mysql.branch).sock" }
        #endif
        return (app?.paths ?? .standard()).mysqlSocket(major: config.mysql.branch).path(percentEncoded: false)
    }

    var phpMyAdminURL: URL {
        (app?.localhostURL ?? URL(string: "http://localhost/")!).appending(path: "phpmyadmin/")
    }

    /// Elasticvue (Elasticsearch web GUI, installed with Elasticsearch) on the localhost site.
    var elasticvueURL: URL {
        (app?.localhostURL ?? URL(string: "http://localhost/")!).appending(path: "elasticvue/")
    }

    /// Shell command for Terminal: RAMP client + socket, password asked interactively (never in the command).
    var clientCommand: String {
        let client = service.mysqlClient(config).path(percentEncoded: false)
        return "\(Self.shellQuote(client)) -uroot -p -S \(Self.shellQuote(mysqlSocket))"
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Database section tab (persisted per viewer in UserDefaults).
enum DatabaseTab: String, CaseIterable, Identifiable {
    case mysql, redis, elasticsearch
    var id: Self { self }
    static let storageKey = "databaseTab"
}

/// `GET /_cluster/health`.
struct ElasticsearchClusterHealth: Decodable, Sendable, Equatable {
    let clusterName: String?
    let status: String
    let numberOfNodes: Int

    enum CodingKeys: String, CodingKey {
        case clusterName = "cluster_name"
        case status
        case numberOfNodes = "number_of_nodes"
    }
}

/// One row of `GET /_cat/indices?format=json&bytes=b` (all values are strings; closed indices have nulls).
struct ElasticsearchIndexInfo: Decodable, Sendable, Identifiable, Equatable {
    let index: String
    let health: String?
    let status: String?
    let docsCount: Int?
    let storeBytes: Int64?

    var id: String { index }

    enum CodingKeys: String, CodingKey {
        case index, health, status
        case docsCount = "docs.count"
        case storeBytes = "store.size"
    }

    init(index: String, health: String?, status: String?, docsCount: Int?, storeBytes: Int64?) {
        self.index = index
        self.health = health
        self.status = status
        self.docsCount = docsCount
        self.storeBytes = storeBytes
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(String.self, forKey: .index)
        health = try c.decodeIfPresent(String.self, forKey: .health)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        docsCount = (try? c.decodeIfPresent(String.self, forKey: .docsCount)).flatMap { $0.flatMap(Int.init) }
        storeBytes = (try? c.decodeIfPresent(String.self, forKey: .storeBytes)).flatMap { $0.flatMap(Int64.init) }
    }
}

/// Minimal read-only HTTP client for the local ES (short timeout, no caching, no cookies).
struct ElasticsearchHTTPClient: Sendable {
    let baseURL: URL

    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { String(localized: "Elasticsearch vrátil HTTP \(status)") }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    func clusterHealth() async throws -> ElasticsearchClusterHealth {
        try await get("_cluster/health", query: [])
    }

    func indices() async throws -> [ElasticsearchIndexInfo] {
        try await get("_cat/indices", query: [URLQueryItem(name: "format", value: "json"),
                                              URLQueryItem(name: "bytes", value: "b")])
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
