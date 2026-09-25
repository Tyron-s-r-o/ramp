import Foundation
import Testing
@testable import RAMPCore

@Suite struct CLIShimGeneratorTests {
    static let shimDir = URL(filePath: "/Users/t/.ramp/bin", directoryHint: .isDirectory)
    let root = GeneratorFixture.rootPath

    func shims(_ mutate: (inout RampConfig) -> Void = { _ in }) -> [String: String] {
        var config = GeneratorFixture.config
        mutate(&config)
        let list = CLIShimGenerator(config: config, paths: GeneratorFixture.paths, shimDir: Self.shimDir).shims()
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.contents) })
    }

    @Test func commandSet() {
        let names = shims().keys.sorted()
        #expect(names == ["composer", "mysql", "mysqladmin", "mysqlcheck", "mysqldump", "php", "php-config",
                          "php-config7.3", "php-config8.2", "php-config8.3", "php-config8.5", "php7.3", "php8.2",
                          "php8.3", "php8.5", "phpize", "phpize7.3", "phpize8.2", "phpize8.3", "phpize8.5", "redis-cli"])
    }

    @Test func goldenVersionedPHP() {
        #expect(shims()["php8.3"] == """
        #!/bin/bash
        # Managed by RAMP — regenerated automatically
        # PHP 8.3 (RAMP) — php.ini: \(root)/conf/php/8.3/php-cli.ini
        export PHP_INI_SCAN_DIR='\(root)/conf/php/8.3/conf.d'
        export OPENSSL_CONF='\(root)/php/8.3/current/ssl/openssl.cnf'
        if [ -z "${SSL_CERT_FILE:-}" ]; then export SSL_CERT_FILE='\(root)/php/8.3/current/ssl/cert.pem'; fi
        exec '\(root)/php/8.3/current/bin/php' -c '\(root)/conf/php/8.3/php-cli.ini' "$@"

        """)
    }

    @Test func goldenDefaultAndTools() {
        let s = shims()
        #expect(s["php"] == """
        #!/bin/bash
        # Managed by RAMP — regenerated automatically
        # php → PHP 8.5 (RAMP terminal default)
        exec '/Users/t/.ramp/bin/php8.5' "$@"

        """)
        #expect(s["phpize8.2"] == """
        #!/bin/bash
        # Managed by RAMP — regenerated automatically
        # phpize of PHP 8.2 (RAMP)
        exec '\(root)/php/8.2/current/bin/phpize' "$@"

        """)
        #expect(s["redis-cli"]!.contains("exec \"$bin\" -p 6379 \"$@\"\n"))
        #expect(s["mysql"]!.contains("--socket='\(root)/run/mysql9.7.sock' \"$@\"\n"))
        #expect(s["composer"]!.contains("phar='\(root)/composer/composer.phar'\n"))
        #expect(s["composer"]!.contains("php='/Users/t/.ramp/bin/php'\"$RAMP_PHP\"\n"))
        #expect(!s["mysql"]!.contains("root".uppercased()) && !s["mysql"]!.contains("--user"))
        #expect(s.values.allSatisfy { $0.hasPrefix("#!/bin/bash\n\(CLIShimGenerator.managedHeader)\n") })
    }

    @Test func defaultBranchResolution() {
        var c = GeneratorFixture.config
        #expect(CLIShimGenerator.defaultBranch(c) == "8.5")          // highest
        c.apache.defaultPHP = "8.2"
        #expect(CLIShimGenerator.defaultBranch(c) == "8.2")          // apache default
        c.cli.defaultPHP = "8.3"
        #expect(CLIShimGenerator.defaultBranch(c) == "8.3")          // cli default wins
        c.php.branches["8.3"] = PHPBranchSettings(enabled: false)
        #expect(CLIShimGenerator.defaultBranch(c) == "8.2")          // disabled → falls through
        c.cli.defaultPHP = "9.9"
        #expect(CLIShimGenerator.defaultBranch(c) == "8.2")
    }

    @Test func disabledBranchHasNoShims() {
        let s = shims { $0.php.branches["7.3"] = PHPBranchSettings(enabled: false) }
        #expect(s["php7.3"] == nil && s["phpize7.3"] == nil)
        #expect(s["php8.2"] != nil)
    }

    @Test func noMySQLOrRedisWithoutPackages() {
        let s = shims { $0.installed["mysql"] = nil; $0.installed["redis"] = nil }
        #expect(s["mysql"] == nil && s["redis-cli"] == nil)
    }

    @Test func pathsWithQuotesAreSafelyQuoted() {
        #expect(CLIShimGenerator.sq("/a b/it's") == #"'/a b/it'\''s'"#)
    }
}

@Suite struct MySQLShimArgsTests {
    @Test(arguments: [
        ([], true),
        (["-uroot", "-proot", "shop"], true),
        (["--defaults-file=/x.cnf", "-e", "select 1"], true),
        (["--help"], true),
        (["-h", "127.0.0.1"], false),
        (["-hdb.example"], false),
        (["--host=db"], false),
        (["--host", "db"], false),
        (["-S", "/tmp/mysql.sock"], false),
        (["-S/tmp/x.sock"], false),
        (["--socket=/tmp/x.sock"], false),
        (["--protocol=TCP"], false),
        (["--protocol", "tcp"], false),
        (["--", "-h"], true),
    ] as [([String], Bool)])
    func detection(args: [String], injects: Bool) {
        #expect(MySQLShimArgs.injectsSocket(args) == injects)
    }

    /// The generated bash shim behaves exactly like `injectsSocket` (run against a fake mysql binary).
    @Test func bashShimMatchesSwift() throws {
        let base = URL(filePath: "/tmp/ramp-shim-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "Application Support/RAMP", directoryHint: .isDirectory)
        let paths = Paths(root: root, logs: base.appending(path: "logs"))
        let bin = paths.current(component: "mysql", branch: "9.7").appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appending(path: "mysql")
        try Data("#!/bin/bash\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path(percentEncoded: false))

        var config = RampConfig()
        config.installed["mysql"] = ["9.7": InstalledPackage(version: "9.7.2", sha256: "0", installedAt: Date())]
        let shimDir = base.appending(path: "home/.ramp/bin", directoryHint: .isDirectory)
        try CLIShimWriter(shimDir: shimDir).sync(CLIShimGenerator(config: config, paths: paths, shimDir: shimDir).shims())
        let socketArg = "--socket=" + paths.mysqlSocket(major: "9.7").path(percentEncoded: false)

        for args in [[], ["-uroot", "shop"], ["-h", "db"], ["-S/x"], ["--protocol=TCP"],
                     ["--defaults-file=/x.cnf", "-e", "select 1"], ["--no-defaults", "--login-path=a", "db"]] {
            let p = Process()
            p.executableURL = shimDir.appending(path: "mysql")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let got = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().map(String.init)
            var expected = args
            if MySQLShimArgs.injectsSocket(args) {
                let lead = args.prefix { $0.hasPrefix("--defaults-") || $0.hasPrefix("--login-path=") || $0 == "--no-defaults" }
                expected = Array(lead) + [socketArg] + args.dropFirst(lead.count)
            }
            #expect(got == expected, "args \(args)")
        }
    }
}

@Suite struct CLIShimWriterTests {
    let dir = URL(filePath: "/tmp/ramp-shim-writer/\(UUID().uuidString)/bin", directoryHint: .isDirectory)

    func shim(_ name: String, _ body: String = "echo hi") -> CLIShim {
        CLIShim(name: name, contents: "#!/bin/bash\n\(CLIShimGenerator.managedHeader)\n\(body)\n")
    }

    @Test func writesReplacesAndPrunesOnlyManagedFiles() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let writer = CLIShimWriter(shimDir: dir)
        var r = try writer.sync([shim("php8.2"), shim("php8.3"), shim("php")])
        #expect(r.written.sorted() == ["php", "php8.2", "php8.3"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "php").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o755)

        // user's own file with a shim name + an unrelated one
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: dir.appending(path: "composer"))
        try Data("mine".utf8).write(to: dir.appending(path: "notes.txt"))

        r = try writer.sync([shim("php8.3", "echo new"), shim("php"), shim("composer")])
        #expect(r.written == ["php8.3"])
        #expect(r.removed == ["php8.2"])
        #expect(r.skipped == ["composer"])
        #expect(try String(contentsOf: dir.appending(path: "composer"), encoding: .utf8) == "#!/bin/sh\necho mine\n")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "notes.txt").path(percentEncoded: false)))

        r = try writer.sync([shim("php8.3", "echo new"), shim("php")])
        #expect(!r.changed)
        #expect(writer.removeAll() == ["php", "php8.3"])
        #expect(writer.managedNames().isEmpty)
    }
}

@Suite struct PHPCLIIniTests {
    let paths = GeneratorFixture.paths
    let root = GeneratorFixture.rootPath

    @Test func cliIniLiftsMemoryLimitAndKeepsLayers() throws {
        var config = GeneratorFixture.config
        config.php.globalIniOverrides = ["upload_max_filesize": "64M"]
        let gen = PHPIniGenerator(config: config, paths: paths)
        let cli = try gen.cliIni(branch: "8.3")
        #expect(cli.path.path(percentEncoded: false) == "\(root)/conf/php/8.3/php-cli.ini")
        #expect(cli.contents.contains("memory_limit=-1\n"))
        #expect(cli.contents.contains("upload_max_filesize=64M\n"))
        #expect(cli.contents.contains("date.timezone=Europe/Bratislava\n"))
        #expect(try gen.files(branch: "8.3")[0].contents.contains("memory_limit=1024M\n"))

        config.php.branches["8.3"] = PHPBranchSettings(iniOverrides: ["memory_limit": "2G"])
        let overridden = try PHPIniGenerator(config: config, paths: paths).cliIni(branch: "8.3")
        #expect(overridden.contents.contains("memory_limit=2G\n"))
    }

    @Test func caBundleInBothInis() throws {
        let gen = PHPIniGenerator(config: GeneratorFixture.config, paths: paths)
        let ca = "\"\(root)/php/8.3/current/ssl/cert.pem\""
        for text in [try gen.files(branch: "8.3")[0].contents, try gen.cliIni(branch: "8.3").contents] {
            #expect(text.contains("curl.cainfo=\(ca)\n"))
            #expect(text.contains("openssl.cafile=\(ca)\n"))
        }
        var config = GeneratorFixture.config
        config.php.globalIniOverrides = ["curl.cainfo": "/etc/ssl/cert.pem"]
        let text = try PHPIniGenerator(config: config, paths: paths).cliIni(branch: "8.3").contents
        #expect(text.components(separatedBy: "curl.cainfo=").count == 2)
        #expect(text.contains("curl.cainfo=\"/etc/ssl/cert.pem\"\n"))
    }

    @Test func cliIniChangeDoesNotReloadFPM() {
        let changed: Set<URL> = [paths.phpCliIni(branch: "8.3")]
        let affected = StackController.affectedServices(changed: changed, paths: paths)
        #expect(affected.reload.isEmpty && affected.restart.isEmpty)
        let php = StackController.affectedServices(changed: [paths.phpIni(branch: "8.3")], paths: paths)
        #expect(php.reload == [.phpFPM("8.3")])
    }

    @Test func renderAllIncludesCliIni() throws {
        let files = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: paths)
        #expect(files.contains { $0.path == paths.phpCliIni(branch: "8.5") })
    }
}

@Suite struct ComposerInstallerTests {
    @Test func downloadVerifiesChecksum() async throws {
        let base = URL(filePath: "/tmp/ramp-composer-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let phar = base.appending(path: "composer.phar")
        let sum = base.appending(path: "composer.phar.sha256sum")
        try Data("<?php echo 'composer';".utf8).write(to: phar)
        // sha256 of the bytes above
        let hex = "fd0f5e3a7e40d0a4b0ee15cc2d22e8b7d0d3c6f1a25bca5b4b0d1c6fa2f1e8f0"
        try Data("\(hex)  composer.phar\n".utf8).write(to: sum)
        let paths = Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
        let installer = ComposerInstaller(paths: paths, pharURL: phar, checksumURL: sum)
        await #expect(throws: ComposerError.self) { try await installer.update() }
        #expect(!installer.isInstalled)

        let real = try ComposerInstaller.sha256(of: phar)
        try Data("\(real)  composer.phar\n".utf8).write(to: sum)
        #expect(try await installer.update() == real)
        #expect(installer.isInstalled)
        #expect(!installer.needsRefresh())
        #expect(installer.needsRefresh(now: Date().addingTimeInterval(8 * 24 * 3600)))
    }

    @Test func checksumParsing() throws {
        let hex = String(repeating: "a", count: 64)
        #expect(try ComposerInstaller.parseChecksum("\(hex)  composer.phar\n") == hex)
        #expect(throws: ComposerError.self) { try ComposerInstaller.parseChecksum("<html>") }
    }
}
