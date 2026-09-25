import Foundation
import Testing
@testable import RAMPCore

/// Plan 04-02: typed per-branch settings → `conf/php/<b>/conf.d/*.ini` fragments.
@Suite struct PHPConfDGeneratorTests {
    let paths = GeneratorFixture.paths
    static let fullManifest = ["apcu", "redis", "imagick", "yaml", "memcached", "phalcon", "xdebug",
                               "opcache", "mbstring", "intl"]

    /// GeneratorFixture + manifest extension lists (8.2/8.3/8.5 full set, 7.3 apcu/redis/xdebug).
    static var config: RampConfig {
        var c = GeneratorFixture.config
        for b in ["8.2", "8.3", "8.5"] { c.installed["php"]![b]!.extensions = fullManifest }
        c.installed["php"]!["7.3"]!.extensions = ["apcu", "redis", "xdebug"]
        return c
    }

    func files(_ branch: String, _ mutate: (inout RampConfig) -> Void = { _ in }) throws -> [GeneratedFile] {
        var c = Self.config
        mutate(&c)
        return try PHPConfDGenerator(config: c, paths: paths).files(branch: branch)
    }

    func names(_ branch: String, _ mutate: (inout RampConfig) -> Void = { _ in }) throws -> [String] {
        try files(branch, mutate).map(\.path.lastPathComponent)
    }

    func text(_ branch: String, _ name: String, _ mutate: (inout RampConfig) -> Void = { _ in }) throws -> String {
        let f = try #require(try files(branch, mutate).first { $0.path.lastPathComponent == name })
        return f.contents
    }

    func settings(_ c: inout RampConfig, _ b: String, _ edit: (inout PHPBranchSettings) -> Void) {
        var s = c.php.branches[b] ?? PHPBranchSettings()
        edit(&s)
        c.php.branches[b] = s
    }

    // MARK: Catalog

    @Test func catalogEntries() {
        #expect(PHPExtensionCatalog.entries.map(\.name) == ["apcu", "imagick", "memcached", "redis", "yaml", "phalcon", "xdebug"])
        #expect(PHPExtensionCatalog.entry("xdebug")?.kind == .zendExtension)
        #expect(PHPExtensionCatalog.entry("xdebug")?.prefix == 90)
        #expect(PHPExtensionCatalog.entry("phalcon")?.prefix == 30)
        #expect(PHPExtensionCatalog.entry("redis")?.kind == .extension)
        #expect(PHPExtensionCatalog.entry("phalcon")?.defaultEnabled(branch: "8.2") == true)
        #expect(PHPExtensionCatalog.entry("phalcon")?.defaultEnabled(branch: "8.3") == false)
        #expect(PHPExtensionCatalog.entry("xdebug")?.defaultEnabled(branch: "8.2") == false)
        #expect(PHPExtensionCatalog.entry("apcu")?.defaultEnabled(branch: "7.3") == true)
    }

    @Test func availableIsManifestIntersectCatalog() {
        let c = Self.config
        #expect(PHPExtensionCatalog.available(branch: "8.3", config: c)
                == ["apcu", "redis", "imagick", "yaml", "memcached", "phalcon", "xdebug"])
        #expect(PHPExtensionCatalog.available(branch: "7.3", config: c) == ["apcu", "redis", "xdebug"])
        var nilExt = c
        nilExt.installed["php"]!["8.3"]!.extensions = nil
        #expect(PHPExtensionCatalog.available(branch: "8.3", config: nilExt).isEmpty)
        #expect(PHPExtensionCatalog.available(branch: "9.9", config: c).isEmpty)
    }

    // MARK: File sets (plan fixtures)

    @Test func php82DefaultSetIncludesPhalcon() throws {
        #expect(try names("8.2") == ["10-opcache.ini", "20-apcu.ini", "20-imagick.ini", "20-memcached.ini",
                                     "20-redis.ini", "20-yaml.ini", "30-phalcon.ini"])
        let dir = paths.phpConfD(branch: "8.2")
        #expect(try files("8.2").allSatisfy { $0.path.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL })
    }

    @Test func php83DefaultHasNoPhalconNoXdebug() throws {
        #expect(try names("8.3") == ["10-opcache.ini", "20-apcu.ini", "20-imagick.ini", "20-memcached.ini",
                                     "20-redis.ini", "20-yaml.ini"])
        for f in try files("8.3") { #expect(!f.contents.contains("xdebug")) }
    }

    @Test func php83XdebugDebugAddsFragment() throws {
        let n = try names("8.3") { settings(&$0, "8.3") { $0.xdebug = .debug } }
        #expect(n.last == "90-xdebug.ini")
        #expect(n.count == 7)
    }

    @Test func php73Set() throws {
        #expect(try names("7.3") == ["10-opcache.ini", "20-apcu.ini", "20-redis.ini"])
        #expect(!(try text("7.3", "10-opcache.ini").contains("jit")))
    }

    @Test func nilExtensionsOnlyOpcache() throws {
        #expect(try names("8.3") { $0.installed["php"]!["8.3"]!.extensions = nil } == ["10-opcache.ini"])
    }

    @Test func explicitChoices() throws {
        // explicit false disables a default-on extension; explicit true enables phalcon on 8.3
        let n = try names("8.3") { settings(&$0, "8.3") { $0.extensions = ["redis": false, "phalcon": true] } }
        #expect(n == ["10-opcache.ini", "20-apcu.ini", "20-imagick.ini", "20-memcached.ini", "20-yaml.ini", "30-phalcon.ini"])
        // explicit false for phalcon on 8.2
        #expect(!(try names("8.2") { settings(&$0, "8.2") { $0.extensions = ["phalcon": false] } }).contains("30-phalcon.ini"))
    }

    @Test func explicitUnavailableThrows() {
        #expect(throws: GeneratorError.extensionUnavailable(branch: "7.3", name: "imagick")) {
            try files("7.3") { settings(&$0, "7.3") { $0.extensions = ["imagick": true] } }
        }
        #expect(throws: GeneratorError.extensionUnavailable(branch: "8.3", name: "mbstring")) {
            try files("8.3") { settings(&$0, "8.3") { $0.extensions = ["mbstring": true] } }
        }
        // explicit false for an unavailable ext is fine
        #expect(throws: Never.self) {
            try files("7.3") { settings(&$0, "7.3") { $0.extensions = ["imagick": false] } }
        }
        #expect(GeneratorError.extensionUnavailable(branch: "7.3", name: "imagick").description
                == "PHP 7.3 package has no imagick extension")
    }

    @Test func xdebugOnlyViaMode() {
        #expect(throws: GeneratorError.invalidValue(key: "php.branches.8.3.extensions", value: "xdebug")) {
            try files("8.3") { settings(&$0, "8.3") { $0.extensions = ["xdebug": true] } }
        }
    }

    @Test func xdebugUnavailableThrows() {
        #expect(throws: GeneratorError.extensionUnavailable(branch: "8.3", name: "xdebug")) {
            try files("8.3") {
                $0.installed["php"]!["8.3"]!.extensions = ["apcu"]
                settings(&$0, "8.3") { $0.xdebug = .profile }
            }
        }
    }

    // MARK: Fragment contents

    @Test func xdebugDebugFragment() throws {
        let t = try text("8.3", "90-xdebug.ini") { settings(&$0, "8.3") { $0.xdebug = .debug } }
        #expect(t == """
        ; Generated by RAMP — do not edit
        ; Xdebug — PHP 8.3, mode debug, trigger only (XDEBUG_TRIGGER cookie/GET/POST), IDE port 9003
        zend_extension=xdebug
        xdebug.mode=debug
        xdebug.start_with_request=trigger
        xdebug.client_host=127.0.0.1
        xdebug.client_port=9003
        xdebug.log_level=0

        """)
    }

    @Test func xdebugProfileFragment() throws {
        let t = try text("8.2", "90-xdebug.ini") { settings(&$0, "8.2") { $0.xdebug = .profile } }
        #expect(t.contains("xdebug.mode=profile\n"))
        #expect(t.contains("xdebug.start_with_request=trigger\n"))
        #expect(t.contains("xdebug.output_dir=\"\(GeneratorFixture.logsPath)/xdebug\"\n"))
    }

    @Test func apcuFragment() throws {
        #expect(try text("8.3", "20-apcu.ini") == """
        ; Generated by RAMP — do not edit
        ; APCu — PHP 8.3
        extension=apcu
        apc.enabled=1
        apc.shm_size=128M
        apc.enable_cli=0

        """)
        #expect(try text("8.3", "20-apcu.ini") { settings(&$0, "8.3") { $0.apcu.shmSize = "256M" } }
            .contains("apc.shm_size=256M\n"))
        #expect(throws: GeneratorError.invalidValue(key: "php.branches.8.3.apcu.shmSize", value: "1 G")) {
            try files("8.3") { settings(&$0, "8.3") { $0.apcu.shmSize = "1 G" } }
        }
    }

    @Test func simpleExtensionFragments() throws {
        for name in ["redis", "imagick", "yaml", "memcached"] {
            #expect(try text("8.3", "20-\(name).ini") == "; Generated by RAMP — do not edit\n; \(name) — PHP 8.3\nextension=\(name)\n")
        }
        #expect(try text("8.2", "30-phalcon.ini").hasSuffix("extension=phalcon\n"))
    }

    @Test func opcacheDefaultUnchanged() throws {
        #expect(try text("8.3", "10-opcache.ini") == PHPIniGolden.opcache)
    }

    @Test func opcachePerformanceProfile() throws {
        let t = try text("8.3", "10-opcache.ini") { settings(&$0, "8.3") { $0.opcache.profile = .performance } }
        #expect(t.contains("opcache.validate_timestamps=0\n"))
        #expect(t.contains("opcache.jit=tracing\nopcache.jit_buffer_size=128M\n"))
        #expect(t.contains("opcache.enable=1\n"))
    }

    @Test func opcacheJitToggle() throws {
        let t = try text("8.5", "10-opcache.ini") { settings(&$0, "8.5") { $0.opcache.jit = true } }
        #expect(t.contains("opcache.validate_timestamps=1\n"))
        #expect(t.contains("opcache.jit=tracing\nopcache.jit_buffer_size=128M\n"))
        // 7.3: JIT does not exist → ignored, no error
        let old = try text("7.3", "10-opcache.ini") {
            settings(&$0, "7.3") { $0.opcache.jit = true; $0.opcache.profile = .performance }
        }
        #expect(!old.contains("jit"))
        #expect(old.contains("opcache.validate_timestamps=0\n"))
    }

    @Test func opcacheDisabledKeepsExtensionLoaded() throws {
        let t = try text("8.3", "10-opcache.ini") { settings(&$0, "8.3") { $0.opcache.enabled = false } }
        #expect(t.contains("zend_extension=opcache\n"))
        #expect(t.contains("opcache.enable=0\n"))
        #expect(!t.contains("opcache.enable=1"))
    }

    @Test func deterministic() throws {
        let a = try files("8.2") { settings(&$0, "8.2") { $0.xdebug = .debug; $0.extensions = ["yaml": false, "redis": true] } }
        let b = try files("8.2") { settings(&$0, "8.2") { $0.extensions = ["redis": true, "yaml": false]; $0.xdebug = .debug } }
        #expect(a == b)
    }

    @Test func enabledExtensions() throws {
        var c = Self.config
        #expect(try PHPConfDGenerator(config: c, paths: paths).enabledExtensions(branch: "8.2")
                == ["apcu", "imagick", "memcached", "redis", "yaml", "phalcon"])
        settings(&c, "8.3") { $0.xdebug = .debug; $0.extensions = ["imagick": false] }
        #expect(try PHPConfDGenerator(config: c, paths: paths).enabledExtensions(branch: "8.3")
                == ["apcu", "memcached", "redis", "yaml", "xdebug"])
    }

    // MARK: PHPIniGenerator delegation

    @Test func phpIniGeneratorDelegatesConfD() throws {
        let all = try PHPIniGenerator(config: Self.config, paths: paths).files(branch: "8.2").map(\.path.lastPathComponent)
        #expect(all == ["php.ini", "10-opcache.ini", "20-apcu.ini", "20-imagick.ini", "20-memcached.ini",
                        "20-redis.ini", "20-yaml.ini", "30-phalcon.ini"])
    }

    // MARK: XdebugStatus

    @Test func xdebugStatus() {
        var c = Self.config
        #expect(XdebugStatus.enabledBranches(c).isEmpty)
        settings(&c, "8.5") { $0.xdebug = .profile }
        settings(&c, "7.3") { $0.xdebug = .debug }
        settings(&c, "8.2") { $0.xdebug = .debug; $0.enabled = false }
        settings(&c, "9.1") { $0.xdebug = .debug }   // not installed
        #expect(XdebugStatus.enabledBranches(c) == ["7.3", "8.5"])
    }
}

/// Config decoding of the new per-branch settings (additive, tolerant).
@Suite struct PHPBranchOptionsConfigTests {
    @Test func missingKeysDecodeToDefaults() throws {
        let c = try RampConfig.decode(from: Data(#"{"schemaVersion":1,"php":{"branches":{"8.3":{"enabled":true}}}}"#.utf8))
        let s = try #require(c.php.branches["8.3"])
        #expect(s.extensions.isEmpty)
        #expect(s.xdebug == .off)
        #expect(s.opcache == OPcacheOptions())
        #expect(s.opcache.enabled && s.opcache.profile == .development && !s.opcache.jit)
        #expect(s.apcu.shmSize == "128M")
    }

    @Test func roundTrip() throws {
        var c = RampConfig()
        c.php.branches["8.2"] = PHPBranchSettings(
            extensions: ["phalcon": true, "redis": false], xdebug: .profile,
            opcache: OPcacheOptions(enabled: true, profile: .performance, jit: true), apcu: APCuOptions(shmSize: "64M"))
        let data = try c.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""xdebug" : "profile""#))
        #expect(json.contains(#""profile" : "performance""#))
        #expect(try RampConfig.decode(from: data) == c)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let c = try RampConfig.decode(from: Data(#"""
        {"schemaVersion":1,"php":{"branches":{"8.3":{"xdebug":"coverage","opcache":{"profile":"turbo","jit":true}}}}}
        """#.utf8))
        let s = try #require(c.php.branches["8.3"])
        #expect(s.xdebug == .off)
        #expect(s.opcache.profile == .development)
        #expect(s.opcache.jit)
    }

    @Test func installedPackageExtensionsOptional() throws {
        let old = try RampConfig.decode(from: Data(#"""
        {"schemaVersion":1,"installed":{"php":{"8.3":{"version":"8.3.35","sha256":"x","installedAt":"2026-09-24T12:00:00Z"}}}}
        """#.utf8))
        #expect(old.installed["php"]?["8.3"]?.extensions == nil)
    }
}
