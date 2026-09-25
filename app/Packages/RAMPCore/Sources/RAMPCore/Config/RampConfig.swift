import Foundation

/// Errors raised while loading / decoding `ramp.json`.
public enum ConfigError: Error, CustomStringConvertible {
    /// The file was written by a newer RAMP (schema > `RampConfig.currentSchemaVersion`). Never downgraded.
    case unsupportedSchema(found: Int, supported: Int)
    /// The file exists but is not valid JSON / not a valid config. The file is left untouched.
    case corrupt(any Error)

    public var description: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            return "ramp.json has schemaVersion \(found), this RAMP supports up to \(supported)"
        case .corrupt(let underlying):
            return "ramp.json is corrupt: \(underlying)"
        }
    }
}

/// `ramp.json` — the single source of truth for RAMP's state (schema v1).
///
/// Decoding is tolerant: every field except `schemaVersion` is optional and falls back to its
/// default, so `{"schemaVersion":1}` yields a full default config; unknown keys are ignored.
/// Example:
/// ```json
/// {
///   "schemaVersion": 1,
///   "manifestURL": "file:///…/build/dist/manifest.json",
///   "installed": { "php": { "8.3": { "version": "8.3.35", "sha256": "…",
///                                    "installedAt": "2026-09-24T12:00:00Z", "extensionDirRel": "lib/php/extensions/…" } } },
///   "apache":   { "port": 80, "listenAddresses": ["127.0.0.1", "::1"] },
///   "php":      { "branches": { "8.3": { "enabled": true, "iniOverrides": {} } } },
///   "mysql":    { "branch": "9.7", "port": 3306, "rootPassword": "root", "initialized": false, "tmpSocketSymlink": true, … },
///   "redis":    { "port": 6379, "bindAddress": "127.0.0.1" },
///   "services": { "apache": { "autostart": true }, … },
///   "vhosts":   [ { "id": "…", "domain": "asteel.local", "aliases": ["admin.asteel.local"],
///                   "docroot": "/Users/…/asteel/www", "phpBranch": "8.3", "enabled": true } ],
///   "hosts":    { "defaultTLD": "local", "manageHostsFile": true },
///   "elasticsearch": { "branch": "9.5", "httpPort": 9200, "heap": "1g", "autoStop": { "afterHours": 6, "atTime": null } }
/// }
/// ```
public struct RampConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Manifest location. `nil` = not configured (set by rampctl / the app, never baked in).
    public var manifestURL: URL?
    /// Installed packages: component → branch → package (e.g. `installed["php"]["8.3"]`).
    public var installed: [String: [String: InstalledPackage]]
    public var apache: ApacheSettings
    public var php: PHPSettings
    public var mysql: MySQLSettings
    public var redis: RedisSettings
    /// Per-service settings keyed by service name (`apache`, `php`, `mysql`, `redis`, …).
    public var services: [String: ServiceSettings]
    /// Virtual hosts (plan 03-02). Additive to schema v1: missing key = no vhosts.
    public var vhosts: [Vhost]
    /// Hosts-file management settings (plan 03-02). Missing key = defaults.
    public var hosts: HostsSettings
    /// Elasticsearch (plan 06-01, optional service). Missing key = defaults.
    public var elasticsearch: ElasticsearchSettings
    /// Update checks / auto-apply (plan 07-01). Missing key = defaults.
    public var updates: UpdateSettings
    /// phpMyAdmin at /phpmyadmin (plan 04-04). Missing key = defaults.
    public var phpmyadmin: PhpMyAdminSettings
    /// Terminal integration (`~/.ramp/bin` shims). Missing key = defaults.
    public var cli: CLISettings

    public static let defaultServices: [String: ServiceSettings] = [
        "apache": ServiceSettings(), "php": ServiceSettings(),
        "mysql": ServiceSettings(), "redis": ServiceSettings(),
    ]

    public init(
        schemaVersion: Int = RampConfig.currentSchemaVersion,
        manifestURL: URL? = nil,
        installed: [String: [String: InstalledPackage]] = [:],
        apache: ApacheSettings = ApacheSettings(),
        php: PHPSettings = PHPSettings(),
        mysql: MySQLSettings = MySQLSettings(),
        redis: RedisSettings = RedisSettings(),
        services: [String: ServiceSettings] = RampConfig.defaultServices,
        vhosts: [Vhost] = [],
        hosts: HostsSettings = HostsSettings(),
        elasticsearch: ElasticsearchSettings = ElasticsearchSettings(),
        updates: UpdateSettings = UpdateSettings(),
        phpmyadmin: PhpMyAdminSettings = PhpMyAdminSettings(),
        cli: CLISettings = CLISettings()
    ) {
        self.schemaVersion = schemaVersion
        self.manifestURL = manifestURL
        self.installed = installed
        self.apache = apache
        self.php = php
        self.mysql = mysql
        self.redis = redis
        self.services = services
        self.vhosts = vhosts
        self.hosts = hosts
        self.elasticsearch = elasticsearch
        self.updates = updates
        self.phpmyadmin = phpmyadmin
        self.cli = cli
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw ConfigError.unsupportedSchema(found: version, supported: Self.currentSchemaVersion)
        }
        let d = RampConfig()
        schemaVersion = version
        manifestURL = try c.decodeIfPresent(URL.self, forKey: .manifestURL)
        installed = try c.decodeIfPresent([String: [String: InstalledPackage]].self, forKey: .installed) ?? d.installed
        apache = try c.decodeIfPresent(ApacheSettings.self, forKey: .apache) ?? d.apache
        php = try c.decodeIfPresent(PHPSettings.self, forKey: .php) ?? d.php
        mysql = try c.decodeIfPresent(MySQLSettings.self, forKey: .mysql) ?? d.mysql
        redis = try c.decodeIfPresent(RedisSettings.self, forKey: .redis) ?? d.redis
        services = try c.decodeIfPresent([String: ServiceSettings].self, forKey: .services) ?? d.services
        vhosts = try c.decodeIfPresent([Vhost].self, forKey: .vhosts) ?? d.vhosts
        hosts = try c.decodeIfPresent(HostsSettings.self, forKey: .hosts) ?? d.hosts
        elasticsearch = try c.decodeIfPresent(ElasticsearchSettings.self, forKey: .elasticsearch) ?? d.elasticsearch
        updates = try c.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? d.updates
        phpmyadmin = try c.decodeIfPresent(PhpMyAdminSettings.self, forKey: .phpmyadmin) ?? d.phpmyadmin
        cli = try c.decodeIfPresent(CLISettings.self, forKey: .cli) ?? d.cli
    }

    /// Decodes `ramp.json` bytes: schema check → `ConfigMigrator` → typed decode.
    /// Malformed input throws `ConfigError.corrupt`, newer schema `ConfigError.unsupportedSchema`.
    public static func decode(from data: Data) throws -> RampConfig {
        let object: [String: any Sendable]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: any Sendable] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "top level is not an object"))
            }
            object = dict
        } catch {
            throw ConfigError.corrupt(error)
        }
        let migrated = try ConfigMigrator.migrate(json: object)
        do {
            let migratedData = try JSONSerialization.data(withJSONObject: migrated)
            return try makeDecoder().decode(RampConfig.self, from: migratedData)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.corrupt(error)
        }
    }

    /// Canonical encoding: pretty-printed, sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One installed package (`installed[component][branch]`).
public struct InstalledPackage: Codable, Sendable, Equatable {
    public var version: String
    public var sha256: String
    public var installedAt: Date
    /// PHP only: extension dir relative to the package root (from manifest `extension_dir_rel`).
    public var extensionDirRel: String?
    /// PHP only: OPcache build type from the package tree's own `ramp.json` — `"shared"` (needs
    /// `zend_extension=opcache`) or `"static"` (always built in, PHP ≥ 8.5). `nil` = unknown (older record).
    public var opcache: String?
    /// PHP only: extensions the package ships (manifest `extensions`, recorded at install). May also list
    /// compiled-in ones; `PHPExtensionCatalog.available` intersects with the catalog. `nil` = unknown (older record).
    public var extensions: [String]?
    /// Version replaced by the last update (still on disk, rollback target). `nil` = none (plan 07-01).
    public var previousVersion: String?
    /// sha256 of `previousVersion`'s archive.
    public var previousSHA256: String?

    public init(version: String, sha256: String, installedAt: Date, extensionDirRel: String? = nil,
                opcache: String? = nil, extensions: [String]? = nil,
                previousVersion: String? = nil, previousSHA256: String? = nil) {
        self.version = version
        self.sha256 = sha256
        self.installedAt = installedAt
        self.extensionDirRel = extensionDirRel
        self.opcache = opcache
        self.extensions = extensions
        self.previousVersion = previousVersion
        self.previousSHA256 = previousSHA256
    }
}

public struct ApacheSettings: Codable, Sendable, Equatable {
    public var port: Int
    public var listenAddresses: [String]
    /// PHP branch for the default site. `nil` = highest installed branch.
    public var defaultPHP: String?
    /// Absolute docroot for http://localhost/. `nil` = `Paths.defaultDocroot`.
    public var documentRoot: String?

    public init(port: Int = 80, listenAddresses: [String] = ["127.0.0.1", "::1"],
                defaultPHP: String? = nil, documentRoot: String? = nil) {
        self.port = port
        self.listenAddresses = listenAddresses
        self.defaultPHP = defaultPHP
        self.documentRoot = documentRoot
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        listenAddresses = try c.decodeIfPresent([String].self, forKey: .listenAddresses) ?? d.listenAddresses
        defaultPHP = try c.decodeIfPresent(String.self, forKey: .defaultPHP)
        documentRoot = try c.decodeIfPresent(String.self, forKey: .documentRoot)
    }
}

public struct PHPSettings: Codable, Sendable, Equatable {
    /// Per-branch settings keyed by branch ("8.3").
    public var branches: [String: PHPBranchSettings]
    /// php.ini overrides applied to every branch (layer between RAMP defaults and per-branch
    /// `iniOverrides`): directive → value. Empty string is a valid value; remove = drop the key.
    public var globalIniOverrides: [String: String]

    public init(branches: [String: PHPBranchSettings] = [:], globalIniOverrides: [String: String] = [:]) {
        self.branches = branches
        self.globalIniOverrides = globalIniOverrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branches = try c.decodeIfPresent([String: PHPBranchSettings].self, forKey: .branches) ?? [:]
        globalIniOverrides = try c.decodeIfPresent([String: String].self, forKey: .globalIniOverrides) ?? [:]
    }
}

public struct PHPBranchSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Per-branch php.ini overrides (top layer, wins over `PHPSettings.globalIniOverrides`): directive → value.
    public var iniOverrides: [String: String]
    /// Optional shared extensions: name → explicit choice; missing key = `PHPExtensionCatalog` default.
    public var extensions: [String: Bool]
    /// Xdebug mode; `.off` = `zend_extension=xdebug` is not written at all.
    public var xdebug: XdebugMode
    public var opcache: OPcacheOptions
    public var apcu: APCuOptions

    public init(enabled: Bool = true, iniOverrides: [String: String] = [:], extensions: [String: Bool] = [:],
                xdebug: XdebugMode = .off, opcache: OPcacheOptions = OPcacheOptions(),
                apcu: APCuOptions = APCuOptions()) {
        self.enabled = enabled
        self.iniOverrides = iniOverrides
        self.extensions = extensions
        self.xdebug = xdebug
        self.opcache = opcache
        self.apcu = apcu
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        iniOverrides = try c.decodeIfPresent([String: String].self, forKey: .iniOverrides) ?? [:]
        extensions = try c.decodeIfPresent([String: Bool].self, forKey: .extensions) ?? [:]
        // Unknown mode strings (newer RAMP / hand edit) fall back to off instead of rejecting ramp.json.
        xdebug = try c.decodeIfPresent(String.self, forKey: .xdebug).flatMap(XdebugMode.init(rawValue:)) ?? .off
        opcache = try c.decodeIfPresent(OPcacheOptions.self, forKey: .opcache) ?? OPcacheOptions()
        apcu = try c.decodeIfPresent(APCuOptions.self, forKey: .apcu) ?? APCuOptions()
    }
}

/// MySQL settings. Defaults mirror MAMP (plan/03-mamp-analysis.md).
public struct MySQLSettings: Codable, Sendable, Equatable {
    public var branch: String
    public var port: Int
    public var bindAddress: String
    public var rootPassword: String
    public var sqlMode: String
    public var maxAllowedPacket: String
    public var innodbBufferPoolSize: String
    /// `true` once the datadir has been initialized (`mysqld --initialize-insecure` + root password).
    public var initialized: Bool
    /// `/tmp/mysql.sock` → RAMP's socket while MySQL runs (`MySQLTmpSocketLink`). Missing key = true.
    public var tmpSocketSymlink: Bool

    public init(branch: String = "9.7", port: Int = 3306, bindAddress: String = "127.0.0.1",
                rootPassword: String = "root",
                sqlMode: String = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION",
                maxAllowedPacket: String = "1G", innodbBufferPoolSize: String = "4G", initialized: Bool = false,
                tmpSocketSymlink: Bool = true) {
        self.branch = branch
        self.port = port
        self.bindAddress = bindAddress
        self.rootPassword = rootPassword
        self.sqlMode = sqlMode
        self.maxAllowedPacket = maxAllowedPacket
        self.innodbBufferPoolSize = innodbBufferPoolSize
        self.initialized = initialized
        self.tmpSocketSymlink = tmpSocketSymlink
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? d.branch
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        rootPassword = try c.decodeIfPresent(String.self, forKey: .rootPassword) ?? d.rootPassword
        sqlMode = try c.decodeIfPresent(String.self, forKey: .sqlMode) ?? d.sqlMode
        maxAllowedPacket = try c.decodeIfPresent(String.self, forKey: .maxAllowedPacket) ?? d.maxAllowedPacket
        innodbBufferPoolSize = try c.decodeIfPresent(String.self, forKey: .innodbBufferPoolSize) ?? d.innodbBufferPoolSize
        initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? d.initialized
        tmpSocketSymlink = try c.decodeIfPresent(Bool.self, forKey: .tmpSocketSymlink) ?? d.tmpSocketSymlink
    }
}

public struct RedisSettings: Codable, Sendable, Equatable {
    public var port: Int
    public var bindAddress: String
    /// e.g. "512mb"; `nil` = unlimited.
    public var maxmemory: String?

    public init(port: Int = 6379, bindAddress: String = "127.0.0.1", maxmemory: String? = nil) {
        self.port = port
        self.bindAddress = bindAddress
        self.maxmemory = maxmemory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        maxmemory = try c.decodeIfPresent(String.self, forKey: .maxmemory)
    }
}

public struct ServiceSettings: Codable, Sendable, Equatable {
    public var autostart: Bool

    public init(autostart: Bool = true) { self.autostart = autostart }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? true
    }
}

/// Upgrades older `ramp.json` documents to `RampConfig.currentSchemaVersion` before typed decoding.
public enum ConfigMigrator {
    /// v1 is the first schema → identity. Future versions add `case n: json = migrateNtoN+1(json)` steps.
    public static func migrate(json: [String: any Sendable]) throws -> [String: any Sendable] {
        guard let version = json["schemaVersion"] as? Int else {
            throw ConfigError.corrupt(DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "schemaVersion missing or not an integer")))
        }
        guard version <= RampConfig.currentSchemaVersion else {
            throw ConfigError.unsupportedSchema(found: version, supported: RampConfig.currentSchemaVersion)
        }
        return json
    }
}
