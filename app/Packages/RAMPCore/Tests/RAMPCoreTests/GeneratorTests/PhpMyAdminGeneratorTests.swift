import Foundation
import Testing
@testable import RAMPCore

/// `GeneratorFixture.config` + phpMyAdmin 5.2.3 installed and a fixed secret.
enum PhpMyAdminFixture {
    static let secret = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"

    static var config: RampConfig {
        var c = GeneratorFixture.config
        c.installed["phpmyadmin"] = ["5.2": GeneratorFixture.pkg("5.2.3")]
        c.phpmyadmin.blowfishSecret = secret
        return c
    }
}

@Suite struct PhpMyAdminGeneratorTests {
    let root = GeneratorFixture.rootPath
    let paths = GeneratorFixture.paths
    var pmaDir: String { "\(root)/phpmyadmin/5.2/current" }

    func files(_ config: RampConfig = PhpMyAdminFixture.config) throws -> [GeneratedFile] {
        try PhpMyAdminConfigGenerator(config: config, paths: paths).files()
    }

    func configPHP(_ config: RampConfig = PhpMyAdminFixture.config) throws -> String {
        try #require(try files(config).first { $0.path.lastPathComponent == "config.inc.php" }).contents
    }

    @Test func filesPathsAndModes() throws {
        let f = try files()
        #expect(f.map { ConfigText.path($0.path) } == ["\(pmaDir)/config.inc.php", "\(pmaDir)/.user.ini"])
        #expect(f.map(\.mode) == [0o600, 0o644])
    }

    @Test func notInstalledOrDisabledRendersNothing() throws {
        #expect(try files(GeneratorFixture.config).isEmpty)
        var c = PhpMyAdminFixture.config
        c.phpmyadmin.enabled = false
        #expect(try files(c).isEmpty)
        #expect(try PhpMyAdminConfigGenerator(config: c, paths: paths).site() == nil)
    }

    @Test func missingSecretThrowsButSiteIsInactive() throws {
        var c = PhpMyAdminFixture.config
        c.phpmyadmin.blowfishSecret = nil
        #expect(throws: GeneratorError.invalidValue(key: "phpmyadmin.blowfishSecret", value: "")) { try files(c) }
        // Renderer / Apache skip phpMyAdmin until StackController has persisted a secret.
        #expect(try PhpMyAdminConfigGenerator(config: c, paths: paths).site() == nil)
        #expect(!(try ConfigRenderer.renderAll(config: c, paths: paths)).contains { $0.path.lastPathComponent == "config.inc.php" })
    }

    @Test(arguments: ["short", "AbCdEfGhIjKlMnOpQrStUvWxYz0123456", "AbCdEfGhIjKlMnOpQrStUvWxYz01234'",
                      "AbCdEfGhIjKlMnOpQrStUvWxYz01234é"])
    func invalidSecretRejected(_ secret: String) {
        var c = PhpMyAdminFixture.config
        c.phpmyadmin.blowfishSecret = secret
        #expect(throws: GeneratorError.self) { try files(c) }
    }

    @Test func autoLoginOverSocket() throws {
        let php = try configPHP()
        #expect(php.hasPrefix("<?php\n\ndeclare(strict_types=1);\n"))
        #expect(php.contains("$cfg['blowfish_secret'] = '\(PhpMyAdminFixture.secret)';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['auth_type'] = 'config';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['connect_type'] = 'socket';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['socket'] = '\(root)/run/mysql9.7.sock';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['user'] = 'root';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['password'] = 'root';\n"))
        #expect(php.contains("$cfg['Servers'][$i]['AllowNoPassword'] = false;\n"))
        #expect(php.contains("$cfg['TempDir'] = '\(root)/tmp/phpmyadmin';\n"))
    }

    @Test func passwordIsEscapedAsPHPLiteral() throws {
        var c = PhpMyAdminFixture.config
        c.mysql.rootPassword = #"a'b\c\"#
        #expect(try configPHP(c).contains(#"$cfg['Servers'][$i]['password'] = 'a\'b\\c\\';"#))
    }

    @Test(arguments: ["a\nb", "a\0b", "a\rb"])
    func passwordControlCharsRejected(_ pw: String) {
        var c = PhpMyAdminFixture.config
        c.mysql.rootPassword = pw
        #expect(throws: GeneratorError.self) { try files(c) }
    }

    @Test func userIniSilencesDeprecations() throws {
        let ini = try #require(try files().last).contents
        #expect(ini.contains("display_errors=Off\n"))
        #expect(ini.contains("error_reporting=E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED\n"))
    }

    @Test func phpBranchSelection() throws {
        let g = PhpMyAdminConfigGenerator(config: PhpMyAdminFixture.config, paths: paths)
        #expect(try g.site()?.phpBranch == "8.5")
        var c = PhpMyAdminFixture.config
        c.php.branches["8.5"] = PHPBranchSettings(enabled: false)
        #expect(try PhpMyAdminConfigGenerator(config: c, paths: paths).site()?.phpBranch == "8.3")
        c.phpmyadmin.phpBranch = "8.2"
        #expect(try PhpMyAdminConfigGenerator(config: c, paths: paths).site()?.phpBranch == "8.2")
        c.phpmyadmin.phpBranch = "8.5"   // disabled
        #expect(throws: GeneratorError.phpBranchNotInstalled("8.5")) { try PhpMyAdminConfigGenerator(config: c, paths: paths).site() }
        // Independent from apache.defaultPHP.
        var d = PhpMyAdminFixture.config
        d.apache.defaultPHP = "7.3"
        #expect(try PhpMyAdminConfigGenerator(config: d, paths: paths).site()?.phpBranch == "8.5")
    }

    @Test func rendererAppendsPmaFilesAfterRedis() throws {
        let all = try ConfigRenderer.renderAll(config: PhpMyAdminFixture.config, paths: paths)
        let names = all.map { $0.path.lastPathComponent }
        let redis = try #require(names.firstIndex(of: "redis.conf"))
        #expect(Array(names[(redis + 1)...]) == ["config.inc.php", ".user.ini"])
        #expect(try ConfigRenderer.renderAll(config: PhpMyAdminFixture.config, paths: paths) == all)
    }

    @Test func pmaFilesNeverTriggerServiceReload() throws {
        let changed = Set(try files().map(\.path))
        let affected = StackController.affectedServices(changed: changed, paths: paths)
        #expect(affected.reload.isEmpty && affected.restart.isEmpty)
    }

    @Test func secretGenerator() throws {
        var seen = Set<String>()
        for _ in 0..<50 {
            let s = try PhpMyAdminConfigGenerator.generateSecret()
            #expect(PhpMyAdminConfigGenerator.isValidSecret(s))
            seen.insert(s)
        }
        #expect(seen.count == 50)
    }

    @Test func settingsDecodeTolerant() throws {
        let c = try RampConfig.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(c.phpmyadmin == PhpMyAdminSettings())
        let d = try RampConfig.decode(from: Data(#"{"schemaVersion":1,"phpmyadmin":{"phpBranch":"8.3"}}"#.utf8))
        #expect(d.phpmyadmin.enabled && d.phpmyadmin.phpBranch == "8.3" && d.phpmyadmin.blowfishSecret == nil)
        var e = PhpMyAdminFixture.config
        e.phpmyadmin.phpBranch = "8.2"
        #expect(try RampConfig.decode(from: e.encoded()) == e)
    }

    @Test func golden() throws {
        #expect(try configPHP() == PhpMyAdminGolden.configPHP)
    }
}

enum PhpMyAdminGolden {
    static let configPHP = #"""
<?php

declare(strict_types=1);

// Generated by RAMP — do not edit (source of truth: ramp.json).

$cfg['blowfish_secret'] = 'AbCdEfGhIjKlMnOpQrStUvWxYz012345';

$i = 1;
$cfg['Servers'][$i]['auth_type'] = 'config';
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['connect_type'] = 'socket';
$cfg['Servers'][$i]['socket'] = '/Users/t/Library/Application Support/RAMP/run/mysql9.7.sock';
$cfg['Servers'][$i]['user'] = 'root';
$cfg['Servers'][$i]['password'] = 'root';
$cfg['Servers'][$i]['AllowNoPassword'] = false;

$cfg['TempDir'] = '/Users/t/Library/Application Support/RAMP/tmp/phpmyadmin';
$cfg['UploadDir'] = '';
$cfg['SaveDir'] = '';
$cfg['VersionCheck'] = false;
$cfg['SendErrorReports'] = 'never';
$cfg['ExecTimeLimit'] = 300;
$cfg['MaxNavigationItems'] = 250;
$cfg['NavigationTreeEnableGrouping'] = false;

"""#
}
