import Foundation
import Testing
@testable import RAMPCore

@Suite struct RampConfigTests {
    private func makePaths() -> Paths {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ramp-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
    }

    private func cleanup(_ p: Paths) {
        try? FileManager.default.removeItem(at: p.root.deletingLastPathComponent())
    }

    @Test func minimalJSONDecodesToDefaults() throws {
        let config = try RampConfig.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(config == RampConfig())
        #expect(config.apache.port == 80)
        #expect(config.apache.listenAddresses == ["127.0.0.1", "::1"])
        #expect(config.mysql.branch == "9.7")
        #expect(config.mysql.rootPassword == "root")
        #expect(config.mysql.innodbBufferPoolSize == "4G")
        #expect(config.redis.port == 6379)
        #expect(config.services["mysql"]?.autostart == true)
        #expect(config.services.count == 4)
        #expect(config.manifestURL == nil)
    }

    @Test func partialSectionsFillDefaults() throws {
        let json = #"{"schemaVersion":1,"mysql":{"port":3307},"php":{"branches":{"8.3":{}}}}"#
        let config = try RampConfig.decode(from: Data(json.utf8))
        #expect(config.mysql.port == 3307)
        #expect(config.mysql.bindAddress == "127.0.0.1")
        #expect(config.php.branches["8.3"] == PHPBranchSettings(enabled: true, iniOverrides: [:]))
    }

    @Test func roundTrip() throws {
        var config = RampConfig()
        config.manifestURL = URL(string: "file:///tmp/dist/manifest.json")
        config.installed["php"] = ["8.3": InstalledPackage(
            version: "8.3.35", sha256: "abc", installedAt: Date(timeIntervalSince1970: 1_790_000_000),
            extensionDirRel: "lib/php/extensions/no-debug-non-zts-20230831")]
        config.apache.defaultPHP = "8.3"
        config.php.branches["8.3"] = PHPBranchSettings(enabled: false, iniOverrides: ["memory_limit": "1G"])
        config.redis.maxmemory = "512mb"
        config.services["elasticsearch"] = ServiceSettings(autostart: false)
        let decoded = try RampConfig.decode(from: config.encoded())
        #expect(decoded == config)
    }

    @Test func unknownKeysIgnored() throws {
        let json = #"{"schemaVersion":1,"future":{"x":1},"apache":{"port":8080,"newThing":true}}"#
        let config = try RampConfig.decode(from: Data(json.utf8))
        #expect(config.apache.port == 8080)
    }

    @Test func newerSchemaRejected() {
        do {
            _ = try RampConfig.decode(from: Data(#"{"schemaVersion":2}"#.utf8))
            Issue.record("expected unsupportedSchema")
        } catch ConfigError.unsupportedSchema(let found, let supported) {
            #expect(found == 2)
            #expect(supported == 1)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func missingFileLoadsDefaults() async throws {
        let p = makePaths()
        defer { cleanup(p) }
        let config = try await ConfigStore(paths: p).load()
        #expect(config == RampConfig())
    }

    @Test func corruptFileThrowsAndIsUntouched() async throws {
        let p = makePaths()
        defer { cleanup(p) }
        try FileManager.default.createDirectory(at: p.root, withIntermediateDirectories: true)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: p.configFile)
        let store = ConfigStore(paths: p)
        do {
            _ = try await store.load()
            Issue.record("expected corrupt")
        } catch ConfigError.corrupt {
            // expected
        }
        #expect(try Data(contentsOf: p.configFile) == garbage)
    }

    @Test func saveCreatesBackupAndMode0600() async throws {
        let p = makePaths()
        defer { cleanup(p) }
        let store = ConfigStore(paths: p)
        var first = RampConfig()
        first.mysql.port = 3301
        try await store.save(first)
        #expect(!FileManager.default.fileExists(atPath: p.configBackup.path(percentEncoded: false)))
        var second = first
        second.mysql.port = 3302
        try await store.save(second)

        let backup = try RampConfig.decode(from: Data(contentsOf: p.configBackup))
        #expect(backup.mysql.port == 3301)
        #expect(try await store.load().mysql.port == 3302)
        let attrs = try FileManager.default.attributesOfItem(atPath: p.configFile.path(percentEncoded: false))
        #expect(attrs[.posixPermissions] as? Int == 0o600)
        let bakAttrs = try FileManager.default.attributesOfItem(atPath: p.configBackup.path(percentEncoded: false))
        #expect(bakAttrs[.posixPermissions] as? Int == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.root.path(percentEncoded: false))
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func concurrentUpdatesDoNotLoseWrites() async throws {
        let p = makePaths()
        defer { cleanup(p) }
        let store = ConfigStore(paths: p)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try await store.update { $0.php.branches["b\(i)"] = PHPBranchSettings() }
                }
            }
            try await group.waitForAll()
        }
        let config = try await store.load()
        #expect(config.php.branches.count == 50)
    }

    // MARK: - Vhosts / hosts (plan 03-02, additive to schema v1)

    @Test func minimalJSONHasNoVhostsAndLocalTLD() throws {
        let config = try RampConfig.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(config.vhosts.isEmpty)
        #expect(config.hosts == HostsSettings(defaultTLD: "local", manageHostsFile: true))
    }

    @Test func vhostsRoundTrip() throws {
        var config = RampConfig()
        config.vhosts = [
            Vhost(domain: "asteel.local", aliases: ["admin.asteel.local"], docroot: "/Users/x/asteel/www"),
            Vhost(domain: "tyrestock.local", docroot: "/Users/x/tyrestock/public", phpBranch: "8.2", enabled: false),
        ]
        config.hosts = HostsSettings(defaultTLD: "test", manageHostsFile: false)
        let decoded = try RampConfig.decode(from: config.encoded())
        #expect(decoded == config)
    }

    @Test func vhostTolerantDecodingIgnoresUnknownKeys() throws {
        let id = UUID()
        let json = """
        {"schemaVersion":1,"hosts":{"defaultTLD":"test"},
         "vhosts":[{"id":"\(id.uuidString)","domain":"a.local","docroot":"/p","future":42}]}
        """
        let config = try RampConfig.decode(from: Data(json.utf8))
        #expect(config.hosts.defaultTLD == "test")
        #expect(config.hosts.manageHostsFile == true)
        #expect(config.vhosts == [Vhost(id: id, domain: "a.local", aliases: [], docroot: "/p", phpBranch: nil, enabled: true)])
        #expect(config.vhosts[0].hostnames == ["a.local"])
    }

    @Test func normalizeDomain() {
        #expect(Vhost.normalizeDomain("asteel", tld: "local") == "asteel.local")
        #expect(Vhost.normalizeDomain("  Front.Asteel.LOCAL ", tld: "local") == "front.asteel.local")
        #expect(Vhost.normalizeDomain("Shop", tld: "test") == "shop.test")
        #expect(Vhost.normalizeDomain("", tld: "local") == "")
    }
}

/// Plan 06-01: `RampConfig.elasticsearch` — tolerant decoding, defaults.
@Suite struct ElasticsearchSettingsTests {
    @Test func defaults() throws {
        let config = try RampConfig.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        let es = config.elasticsearch
        #expect(es == ElasticsearchSettings())
        #expect(es.branch == "9.5")
        #expect(es.httpPort == 9200)
        #expect(es.transportPort == 9300)
        #expect(es.bindAddress == "127.0.0.1")
        #expect(es.heap == "1g")
        #expect(es.plugins.isEmpty)
        #expect(es.autoStop == AutoStopSettings())
        #expect(es.autoStop.afterHours == 6)
        #expect(es.autoStop.atTime == nil)
    }

    @Test func partialDecodeFillsDefaults() throws {
        let json = #"{"schemaVersion":1,"elasticsearch":{"heap":"2g","plugins":["analysis-icu"],"autoStop":{"atTime":"01:00"}}}"#
        let es = try RampConfig.decode(from: Data(json.utf8)).elasticsearch
        #expect(es.heap == "2g")
        #expect(es.plugins == ["analysis-icu"])
        #expect(es.httpPort == 9200)
        #expect(es.autoStop.atTime == "01:00")
        #expect(es.autoStop.afterHours == 6)
    }

    @Test func explicitNullDisablesAfterHours() throws {
        let json = #"{"schemaVersion":1,"elasticsearch":{"autoStop":{"afterHours":null}}}"#
        #expect(try RampConfig.decode(from: Data(json.utf8)).elasticsearch.autoStop.afterHours == nil)
    }

    @Test func roundTrip() throws {
        var config = RampConfig()
        config.elasticsearch = ElasticsearchSettings(branch: "9.5", httpPort: 9201, transportPort: 9301,
                                                     bindAddress: "::1", heap: "512m", plugins: ["analysis-icu"],
                                                     autoStop: AutoStopSettings(afterHours: nil, atTime: "01:00"))
        let decoded = try RampConfig.decode(from: config.encoded())
        #expect(decoded == config)
    }

    @Test func oldConfigWithoutKeyUnchanged() throws {
        let json = #"{"schemaVersion":1,"mysql":{"port":3307},"redis":{"port":6380}}"#
        let config = try RampConfig.decode(from: Data(json.utf8))
        #expect(config.mysql.port == 3307)
        #expect(config.redis.port == 6380)
        #expect(config.elasticsearch == ElasticsearchSettings())
        #expect(config.services.count == 4)
    }
}
