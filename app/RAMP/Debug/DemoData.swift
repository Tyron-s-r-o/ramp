#if DEBUG
import Foundation
import RAMPCore

/// Demo data for `ScreenshotMode` (DEBUG only): a realistic but fictional stack — no real project names,
/// paths or state. Everything the models would otherwise read from running services comes from here.
@MainActor
enum DemoData {
    static let phpVersions: [String: String] = [
        "7.4": "7.4.33", "8.2": "8.2.30", "8.3": "8.3.31", "8.4": "8.4.18", "8.5": "8.5.10",
    ]
    static let defaultPHP = "8.4"
    static let mysqlBranch = "9.7"

    // MARK: ramp.json

    static func config() -> RampConfig {
        let installedAt = Date(timeIntervalSinceNow: -12 * 86_400)
        func pkg(_ version: String, extensions: [String]? = nil) -> InstalledPackage {
            InstalledPackage(version: version, sha256: String(repeating: "0", count: 64), installedAt: installedAt,
                             extensionDirRel: extensions == nil ? nil : "lib/php/extensions/no-debug-non-zts",
                             extensions: extensions)
        }
        var php: [String: InstalledPackage] = [:]
        for (branch, version) in phpVersions {
            var ext = ["apcu", "imagick", "memcached", "redis", "yaml", "xdebug"]
            if branch == "8.2" || branch == "8.3" { ext.append("phalcon") }
            php[branch] = pkg(version, extensions: ext)
        }
        var config = RampConfig(
            installed: [
                "apache": ["2.4": pkg("2.4.68")],
                "php": php,
                "mysql": [mysqlBranch: pkg("9.7.0")],
                "redis": ["8.2": pkg("8.2.3")],
                "phpmyadmin": ["5.2": pkg("5.2.3")],
                "elasticsearch": ["9.5": pkg("9.5.4")],
            ],
            apache: ApacheSettings(port: 80, defaultPHP: defaultPHP),
            mysql: MySQLSettings(branch: mysqlBranch, port: 3306, rootPassword: "root", initialized: true),
            redis: RedisSettings(port: 6379),
            vhosts: vhosts(),
            elasticsearch: ElasticsearchSettings(branch: "9.5", heap: "1g", plugins: ["analysis-icu"],
                                                 autoStop: AutoStopSettings(afterHours: 6)))
        config.php.branches["8.4"] = PHPBranchSettings(
            opcache: OPcacheOptions(enabled: true, profile: .development, jit: false),
            apcu: APCuOptions(shmSize: "256M"))
        config.php.branches["8.5"] = PHPBranchSettings(opcache: OPcacheOptions(enabled: true, profile: .performance, jit: true))
        config.php.branches["8.2"] = PHPBranchSettings(extensions: ["phalcon": true])
        config.php.globalIniOverrides = ["memory_limit": "1G", "upload_max_filesize": "256M", "post_max_size": "256M"]
        return config
    }

    static func vhosts() -> [Vhost] {
        let sites = "/Users/demo/Sites"
        func v(_ domain: String, _ docroot: String, php: String? = nil, group: String?, aliases: [String] = [],
               enabled: Bool = true) -> Vhost {
            Vhost(domain: domain, aliases: aliases, docroot: "\(sites)/\(docroot)", phpBranch: php,
                  enabled: enabled, group: group)
        }
        return [
            v("shop.local", "acme/shop/public", php: "8.4", group: "Acme", aliases: ["www.shop.local"]),
            v("api.shop.local", "acme/shop-api/public", php: "8.5", group: "Acme"),
            v("docs.local", "acme/docs/build", php: "8.3", group: "Acme"),
            v("crm.local", "client-x/crm/public", php: "8.2", group: "Client X"),
            v("admin.crm.local", "client-x/crm/admin", php: "8.2", group: "Client X"),
            v("legacy-erp.local", "client-x/legacy-erp/www", php: "7.4", group: "Client X"),
            v("newsroom.local", "client-x/newsroom/web", php: "8.3", group: "Client X"),
            v("blog.local", "personal/blog/public", group: "Personal"),
        ]
    }

    static var editorVhost: Vhost { vhosts()[0] }

    // MARK: Services

    private static let launched = Date(timeIntervalSinceNow: -(3 * 3600 + 12 * 60 + 41))

    static func serviceRows(_ config: RampConfig) -> [ServiceRowState] {
        func running(_ pid: Int32, _ offset: TimeInterval = 0) -> ServiceState {
            .running(pid: pid, since: launched.addingTimeInterval(offset))
        }
        var rows: [ServiceRowState] = []
        let branches = phpVersions.keys.compactMap(PHPBranch.init).sorted().map(\.description)
        for (i, b) in branches.enumerated() {
            rows.append(ServiceRowState(id: .phpFPM(b), displayName: ServiceID.phpFPM(b).displayName,
                                        state: running(Int32(71_204 + i * 7), TimeInterval(i)), port: nil))
        }
        rows.append(ServiceRowState(id: .apache, displayName: "Apache", state: running(71_262, 2), port: 80))
        rows.append(ServiceRowState(id: .mysql(mysqlBranch), displayName: "MySQL", state: running(71_190), port: 3306))
        rows.append(ServiceRowState(id: .redis, displayName: "Redis", state: running(71_188), port: 6379))
        rows.append(ServiceRowState(id: .elasticsearch, displayName: "Elasticsearch", state: .stopped, port: 9200))
        return rows
    }

    static func expectedServices(_ rows: [ServiceRowState]) -> Set<ServiceID> {
        Set(rows.map(\.id).filter { $0 != .elasticsearch })
    }

    // MARK: PHP

    static func extensions(branch: String, config: RampConfig) -> (available: Set<String>, enabled: [String]) {
        let available = PHPExtensionCatalog.available(branch: branch, config: config)
        let settings = config.php.branches[branch] ?? PHPBranchSettings()
        let enabled = PHPExtensionCatalog.entries.filter { entry in
            guard available.contains(entry.name) else { return false }
            if entry.name == "xdebug" { return settings.xdebug != .off }
            return settings.extensions[entry.name] ?? entry.defaultEnabled(branch: branch)
        }.map(\.name)
        return (available, enabled)
    }

    static let terminalCommands = ["php", "php7.4", "php8.2", "php8.3", "php8.4", "php8.5", "composer", "phpize",
                                   "php-config", "pecl", "mysql", "mysqldump", "mysqladmin", "redis-cli"]

    // MARK: Databases

    static let mysqlVersion = "9.7.0"
    static let databases: [DatabaseSize] = [
        DatabaseSize(name: "acme_shop", bytes: 1_288_490_189, tables: 214),
        DatabaseSize(name: "acme_shop_api", bytes: 96_468_992, tables: 38),
        DatabaseSize(name: "blog", bytes: 24_117_248, tables: 12),
        DatabaseSize(name: "crm", bytes: 356_515_840, tables: 87),
        DatabaseSize(name: "docs", bytes: 7_340_032, tables: 9),
        DatabaseSize(name: "legacy_erp", bytes: 2_147_483_648, tables: 412),
        DatabaseSize(name: "newsroom", bytes: 536_870_912, tables: 64),
    ]
    static let redis = RedisInfo(version: "8.2.3", usedMemoryHuman: "18.47M", keys: 1_284)

    /// Demo keys for a Redis key browser (if present).
    static let redisKeys: [String] = [
        "cache:category:shoes", "cache:category:sale", "cache:config:acme_shop", "cache:menu:main",
        "cache:product:1042", "cache:product:1043", "cache:product:2210", "cache:product:3187",
        "lock:import:catalog", "queue:mail", "queue:search-index", "queue:webhooks",
        "rate:api:203.0.113.7", "rate:api:198.51.100.24",
        "session:3ab8d0c51e2f", "session:9f1c2e7a4b60", "session:c47e19f2d8aa", "session:e02b77c19d35",
        "stats:visits:2026-09-24", "stats:visits:2026-09-25",
    ]

    static func redisType(of key: String) -> String {
        switch key.split(separator: ":").first {
        case "cache": key.hasPrefix("cache:product") ? "hash" : "string"
        case "queue": "list"
        case "rate": "zset"
        default: "string"
        }
    }

    static let esHealth = ElasticsearchClusterHealth(clusterName: "ramp", status: "green", numberOfNodes: 1)
    static let esIndices: [ElasticsearchIndexInfo] = [
        ElasticsearchIndexInfo(index: "acme_products", health: "green", status: "open", docsCount: 48_210,
                               storeBytes: 184_549_376),
        ElasticsearchIndexInfo(index: "acme_categories", health: "green", status: "open", docsCount: 1_320,
                               storeBytes: 2_621_440),
        ElasticsearchIndexInfo(index: "newsroom_articles", health: "green", status: "open", docsCount: 12_904,
                               storeBytes: 96_468_992),
    ]
}

#endif
