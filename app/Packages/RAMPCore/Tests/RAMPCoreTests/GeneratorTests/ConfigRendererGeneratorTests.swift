import Foundation
import Testing
@testable import RAMPCore

@Suite struct ConfigRendererGeneratorTests {
    let paths = GeneratorFixture.paths

    func opcacheIni(_ branch: String) -> URL {
        paths.phpConfD(branch: branch).appending(path: "10-opcache.ini", directoryHint: .notDirectory)
    }

    @Test func managedDirectoriesIncludeConfDOfEnabledBranches() throws {
        var c = GeneratorFixture.config
        c.php.branches["7.3"] = PHPBranchSettings(enabled: false)
        let managed = ConfigRenderer.managedDirectories(config: c, paths: paths)
        let confD = managed.filter { $0.ext == "ini" }.map(\.dir)
        #expect(confD == ["8.2", "8.3", "8.5"].map { paths.phpConfD(branch: $0) })
        // Every rendered conf.d file lives in a managed directory (so stale fragments can be pruned).
        let files = try ConfigRenderer.renderAll(config: c, paths: paths)
        for f in files where f.path.pathExtension == "ini" && f.path.lastPathComponent != "php.ini"
            && f.path.lastPathComponent != Paths.phpCliIniName {
            #expect(confD.map(ConfigText.path).contains(ConfigText.path(f.path.deletingLastPathComponent())))
        }
    }

    @Test func rendersAllFilesInStableOrder() throws {
        let files = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: paths)
        #expect(files.map(\.path) == [
            paths.apacheConf,
            paths.fpmConf(branch: "7.3"), paths.phpIni(branch: "7.3"), opcacheIni("7.3"),
            paths.phpCliIni(branch: "7.3"),
            paths.fpmConf(branch: "8.2"), paths.phpIni(branch: "8.2"), opcacheIni("8.2"),
            paths.phpCliIni(branch: "8.2"),
            paths.fpmConf(branch: "8.3"), paths.phpIni(branch: "8.3"), opcacheIni("8.3"),
            paths.phpCliIni(branch: "8.3"),
            paths.fpmConf(branch: "8.5"), paths.phpIni(branch: "8.5"), opcacheIni("8.5"),
            paths.phpCliIni(branch: "8.5"),
            paths.mysqlConf(major: "9.7"),
            paths.redisConf,
        ])
        #expect(files.allSatisfy { $0.mode == 0o644 })
    }

    @Test func vhostFilesFollowHttpdConf() throws {
        let files = try ConfigRenderer.renderAll(config: VhostGeneratorFixture.config, paths: paths)
        let vhostDir = paths.apacheVhostsDir
        #expect(Array(files.map(\.path).prefix(4)) == [
            paths.apacheConf,
            vhostDir.appending(path: "asteel.local.conf", directoryHint: .notDirectory),
            vhostDir.appending(path: "mysite.local.conf", directoryHint: .notDirectory),
            vhostDir.appending(path: "tyrestock.local.conf", directoryHint: .notDirectory),
        ])
        #expect(files[4].path == paths.fpmConf(branch: "7.3"))
        #expect(try ConfigRenderer.renderAll(config: VhostGeneratorFixture.config, paths: paths) == files)
    }

    @Test func noVhostFilesWithoutApache() throws {
        var c = VhostGeneratorFixture.config
        c.installed["apache"] = nil
        let files = try ConfigRenderer.renderAll(config: c, paths: paths)
        #expect(!files.contains { $0.path.deletingLastPathComponent().lastPathComponent == "vhosts" })
    }

    @Test func managedDirectoriesIncludeApacheVhosts() throws {
        let managed = ConfigRenderer.managedDirectories(config: VhostGeneratorFixture.config, paths: paths)
        #expect(managed.first?.dir == paths.apacheVhostsDir)
        #expect(managed.first?.ext == "conf")
        let files = try ConfigRenderer.renderAll(config: VhostGeneratorFixture.config, paths: paths)
        let vhostFiles = files.filter { $0.path.pathExtension == "conf" && $0.path != paths.apacheConf
            && ConfigText.path($0.path.deletingLastPathComponent()) == ConfigText.path(paths.apacheVhostsDir) }
        #expect(vhostFiles.count == 3)
    }

    @Test func deterministic() throws {
        let a = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: paths)
        let b = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: paths)
        #expect(a == b)
        #expect(a.map { Data($0.contents.utf8) } == b.map { Data($0.contents.utf8) })
    }

    @Test func skipsDisabledAndMissingComponents() throws {
        var c = GeneratorFixture.config
        c.php.branches["7.3"] = PHPBranchSettings(enabled: false)
        c.installed["redis"] = nil
        c.installed["mysql"] = nil
        let files = try ConfigRenderer.renderAll(config: c, paths: paths)
        #expect(!files.contains { $0.path == paths.phpIni(branch: "7.3") })
        #expect(!files.contains { $0.path == paths.redisConf })
        #expect(!files.contains { $0.path == paths.mysqlConf(major: "9.7") })
        #expect(files.contains { $0.path == paths.apacheConf })
    }
}

@Suite struct ConfigWriterGeneratorTests {
    func tempPaths() -> Paths {
        // Short base (sun_path limit) that still contains a space.
        let base = URL(filePath: "/tmp/ramp w-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        return Paths(root: base.appending(path: "root", directoryHint: .isDirectory),
                     logs: base.appending(path: "logs", directoryHint: .isDirectory))
    }

    @Test func writesOnlyChangedFiles() throws {
        let p = tempPaths()
        defer { try? FileManager.default.removeItem(at: p.root.deletingLastPathComponent()) }
        let writer = ConfigWriter(paths: p)
        let a = GeneratedFile(path: p.apacheConf, contents: "A\n", mode: 0o644)
        let b = GeneratedFile(path: p.redisConf, contents: "B\n", mode: 0o600)

        let first = try writer.write([a, b])
        #expect(first == [p.apacheConf, p.redisConf])
        #expect(try String(contentsOf: p.apacheConf, encoding: .utf8) == "A\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: p.redisConf.path(percentEncoded: false))
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        #expect(try writer.write([a, b]).isEmpty)

        let a2 = GeneratedFile(path: p.apacheConf, contents: "A2\n", mode: 0o644)
        #expect(try writer.write([a2, b]) == [p.apacheConf])
        #expect(try String(contentsOf: p.apacheConf, encoding: .utf8) == "A2\n")

        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.apacheConfDir.path(percentEncoded: false))
        #expect(leftovers == ["httpd.conf"])
    }

    @Test func refusesPathsOutsideRoot() throws {
        let p = tempPaths()
        defer { try? FileManager.default.removeItem(at: p.root.deletingLastPathComponent()) }
        let writer = ConfigWriter(paths: p)
        let inside = GeneratedFile(path: p.redisConf, contents: "x", mode: 0o644)
        let outside = GeneratedFile(path: p.root.appending(path: "../evil.conf"), contents: "x", mode: 0o644)
        let sibling = GeneratedFile(path: URL(filePath: String(p.root.path(percentEncoded: false).dropLast()) + "-evil/x.conf"),
                                    contents: "x", mode: 0o644)
        #expect(throws: ConfigWriterError.self) { try writer.write([inside, outside]) }
        #expect(throws: ConfigWriterError.self) { try writer.write([sibling]) }
        // Validation happens before any write.
        #expect(!FileManager.default.fileExists(atPath: p.redisConf.path(percentEncoded: false)))
    }

    @Test func endToEndRenderThenWrite() throws {
        let p = tempPaths()
        defer { try? FileManager.default.removeItem(at: p.root.deletingLastPathComponent()) }
        let files = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: p)
        let writer = ConfigWriter(paths: p)
        #expect(try writer.write(files).count == files.count)
        #expect(try writer.write(files).isEmpty)
    }
}
