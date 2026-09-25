import Foundation
import Testing
@testable import RAMPCore

@Suite struct PHPIniLayersTests {
    let root = GeneratorFixture.rootPath
    let paths = GeneratorFixture.paths

    func effective(_ branch: String, _ config: RampConfig = GeneratorFixture.config) throws -> [IniDirective] {
        try PHPIniLayers.effective(config: config, branch: branch, paths: paths)
    }

    func value(_ directives: [IniDirective], _ key: String) -> IniDirective? {
        directives.first { $0.key == key }
    }

    @Test func baseDefaultsInTableOrder() throws {
        let d = try effective("8.3")
        #expect(d.map(\.key) == [
            "memory_limit", "max_execution_time", "max_input_time", "post_max_size", "upload_max_filesize",
            "display_errors", "display_startup_errors", "log_errors", "error_reporting", "date.timezone",
            "mysqli.default_socket", "pdo_mysql.default_socket", "upload_tmp_dir", "sys_temp_dir", "session.save_path",
        ])
        #expect(d.allSatisfy { $0.source == .base })
        #expect(value(d, "memory_limit")?.value == "1024M")
        #expect(value(d, "date.timezone")?.value == "Europe/Bratislava")
        #expect(value(d, "session.save_path")?.value == "\(root)/tmp")
        #expect(value(d, "mysqli.default_socket")?.value == "\(root)/run/mysql9.7.sock")
    }

    @Test func baseIsIdenticalForEveryBranch() throws {
        let reference = try effective("8.3")
        for branch in ["7.3", "8.2", "8.5"] {
            #expect(try effective(branch) == reference)
        }
    }

    @Test func laterLayerWinsWithProvenance() throws {
        var c = GeneratorFixture.config
        c.php.globalIniOverrides = ["memory_limit": "2048M"]
        c.php.branches["7.3"] = PHPBranchSettings(iniOverrides: ["memory_limit": "512M"])
        #expect(value(try effective("7.3", c), "memory_limit") == IniDirective(key: "memory_limit", value: "512M", source: .branch))
        #expect(value(try effective("8.3", c), "memory_limit") == IniDirective(key: "memory_limit", value: "2048M", source: .global))
    }

    @Test func overrideOnlyKeysAppendedSortedAfterBase() throws {
        var c = GeneratorFixture.config
        c.php.globalIniOverrides = ["zend.assertions": "1", "disable_functions": ""]
        c.php.branches["8.3"] = PHPBranchSettings(iniOverrides: ["apc_like.x": "1", "default_charset": "UTF-8"])
        let d = try effective("8.3", c)
        #expect(Array(d.map(\.key).suffix(4)) == ["apc_like.x", "default_charset", "disable_functions", "zend.assertions"])
        #expect(value(d, "disable_functions") == IniDirective(key: "disable_functions", value: "", source: .global))
        #expect(value(d, "default_charset")?.source == .branch)
        // Base order unchanged.
        #expect(d.first?.key == "memory_limit")
        // Other branch does not see 8.3's overrides.
        #expect(value(try effective("8.2", c), "default_charset") == nil)
    }

    @Test func invalidKeysRejected() {
        for key in ["", "1abc", "memory limit", "a=b", "x[", "x[]", "a;b", "a\nb", "sess ion"] {
            var c = GeneratorFixture.config
            c.php.globalIniOverrides = [key: "1"]
            #expect(throws: GeneratorError.invalidValue(key: "php.iniOverrides", value: key)) {
                try effective("8.3", c)
            }
        }
    }

    @Test func validKeysAccepted() throws {
        var c = GeneratorFixture.config
        c.php.branches["8.3"] = PHPBranchSettings(iniOverrides: [
            "session.cookie_lifetime": "0", "_x": "1", "mbstring.func_overload[a.b-c]": "1",
        ])
        #expect(try effective("8.3", c).count == PHPIniDefaults.base.count + 5 + 3)
    }

    @Test func protectedKeysRejected() {
        for key in ["extension", "zend_extension", "extension_dir", "opcache.enable", "opcache.jit",
                    "xdebug.mode", "apc.shm_size", "OPCACHE.enable", "Extension"] {
            var c = GeneratorFixture.config
            c.php.branches["8.3"] = PHPBranchSettings(iniOverrides: [key: "1"])
            #expect(throws: GeneratorError.invalidValue(key: "php.iniOverrides", value: key)) {
                try effective("8.3", c)
            }
        }
    }

    @Test func protectedCheckIgnoresOtherBranches() throws {
        var c = GeneratorFixture.config
        c.php.branches["8.2"] = PHPBranchSettings(iniOverrides: ["xdebug.mode": "debug"])
        #expect(throws: GeneratorError.self) { try effective("8.2", c) }
        _ = try effective("8.3", c)
    }

    @Test func controlCharactersInValuesRejected() {
        for v in ["a\nb", "a\rb", "a\0b"] {
            var c = GeneratorFixture.config
            c.php.globalIniOverrides = ["user_agent": v]
            #expect(throws: GeneratorError.self) { try effective("8.3", c) }
        }
    }

    @Test func encodeRawWhenSafe() throws {
        #expect(try PHPIniLayers.encode("1024M") == "1024M")
        #expect(try PHPIniLayers.encode("E_ALL & ~E_DEPRECATED & ~E_STRICT") == "E_ALL & ~E_DEPRECATED & ~E_STRICT")
        #expect(try PHPIniLayers.encode("") == "")
        #expect(try PHPIniLayers.encode("Europe/Bratislava") == "Europe/Bratislava")
        #expect(try PHPIniLayers.encode("exec,system,passthru") == "exec,system,passthru")
    }

    @Test func encodeQuotesEverythingElse() throws {
        #expect(try PHPIniLayers.encode(" lead") == "\" lead\"")
        #expect(try PHPIniLayers.encode("trail ") == "\"trail \"")
        #expect(try PHPIniLayers.encode("a;b") == "\"a;b\"")
        #expect(try PHPIniLayers.encode("a=b") == "\"a=b\"")
        #expect(try PHPIniLayers.encode(#"q"x\y"#) == #""q\"x\\y""#)
        // `$` never expands: always quoted and escaped.
        #expect(try PHPIniLayers.encode("${HOME}") == #""\${HOME}""#)
        #expect(try PHPIniLayers.encode("a$b") == #""a\$b""#)
        // Paths are always quoted.
        #expect(try PHPIniLayers.encode("/tmp/x") == "\"/tmp/x\"")
        #expect(try PHPIniLayers.encode("\(root)/tmp") == "\"\(root)/tmp\"")
        #expect(throws: GeneratorError.self) { try PHPIniLayers.encode("a\nb") }
    }
}

@Suite struct PHPIniConfigFieldTests {
    @Test func oldRampJSONDecodesWithEmptyGlobalOverrides() throws {
        let json = #"{"schemaVersion":1,"php":{"branches":{"8.3":{"iniOverrides":{"memory_limit":"1G"}}}},"#
            + #""installed":{"php":{"8.3":{"version":"8.3.35","sha256":"00","installedAt":"2026-09-24T12:00:00Z"}}}}"#
        let c = try RampConfig.decode(from: Data(json.utf8))
        #expect(c.php.globalIniOverrides.isEmpty)
        #expect(c.php.branches["8.3"]?.iniOverrides == ["memory_limit": "1G"])
        #expect(c.installed["php"]?["8.3"]?.opcache == nil)
    }

    @Test func globalOverridesAndOpcacheRoundTrip() throws {
        var c = RampConfig()
        c.php.globalIniOverrides = ["memory_limit": "2G", "disable_functions": ""]
        c.installed["php"] = ["8.5": InstalledPackage(version: "8.5.11", sha256: "00",
                                                     installedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                     extensionDirRel: "lib", opcache: "static")]
        #expect(try RampConfig.decode(from: c.encoded()) == c)
    }
}
