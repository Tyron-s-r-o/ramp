import Foundation
import Testing
@testable import RAMPCore

@Suite struct PackageInstallerTests {
    private let fm = FileManager.default

    private func makeInstaller(_ fx: FixtureBuilder) -> (PackageInstaller, ConfigStore) {
        let store = ConfigStore(paths: fx.paths)
        return (PackageInstaller(paths: fx.paths, configStore: store), store)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }

    private func contents(_ url: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
    }

    private func linkTarget(_ url: URL) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
    }

    /// Asserts the failed install left no trace in `<root>/<component>`, `.staging`, downloads or ramp.json.
    private func expectNothingInstalled(_ fx: FixtureBuilder, _ store: ConfigStore, component: String) async throws {
        #expect(!exists(fx.paths.root.appending(path: component)))
        #expect(contents(fx.paths.staging).isEmpty)
        #expect(contents(fx.paths.downloads).isEmpty)
        #expect(try await store.load().installed.isEmpty)
    }

    // MARK: Happy path

    @Test func installsPHPWithTopLevelDir() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35")
        let manifest = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: archive,
                                              extensionDirRel: "lib/php/extensions/no-debug-non-zts-20230831")])
        let (installer, store) = makeInstaller(fx)

        let record = try await installer.install(component: "php", branch: "8.3", from: manifest)

        let pkg = fx.paths.package(component: "php", version: "8.3.35")
        let fpm = pkg.appending(path: "sbin/php-fpm")
        #expect(fm.isExecutableFile(atPath: fpm.path(percentEncoded: false)))
        #expect(exists(pkg.appending(path: "share/VERSION")))
        #expect(linkTarget(fx.paths.current(component: "php", branch: "8.3")) == "../8.3.35")
        #expect(fm.isExecutableFile(atPath: fx.paths.current(component: "php", branch: "8.3")
            .appending(path: "sbin/php-fpm").path(percentEncoded: false)))

        #expect(record.version == "8.3.35")
        #expect(record.sha256 == archive.sha256)
        #expect(record.extensionDirRel == "lib/php/extensions/no-debug-non-zts-20230831")
        #expect(record.extensions == ["opcache", "intl"])   // 04-02: manifest `extensions` recorded
        let saved = try await store.load().installed["php"]?["8.3"]
        #expect(saved == record)
        #expect(contents(fx.paths.staging).isEmpty)
    }

    /// ISS-001: the PHP tree's own ramp.json (`"opcache": "shared"|"static"`) is recorded at install time.
    @Test func recordsOpcacheBuildTypeFromTreeRampJSON() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let tree = #"{"component":"php","version":"8.5.11","opcache":"static","sapis":["cli","fpm"]}"#
        let archive = try fx.package("php", version: "8.5.11", topLevelDir: "8.5.11", extraFiles: ["ramp.json": tree])
        let plain = try fx.package("php", version: "8.3.35")
        let manifest = try fx.manifest([
            .init(component: "php", branch: "8.5", version: "8.5.11", archive: archive, extensionDirRel: "lib/x"),
            .init(component: "php", branch: "8.3", version: "8.3.35", archive: plain, extensionDirRel: "lib/y"),
        ])
        let (installer, store) = makeInstaller(fx)

        #expect(try await installer.install(component: "php", branch: "8.5", from: manifest).opcache == "static")
        #expect(try await installer.install(component: "php", branch: "8.3", from: manifest).opcache == nil)
        #expect(try await store.load().installed["php"]?["8.5"]?.opcache == "static")
    }

    @Test func installsTreeWithoutTopLevelDir() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("apache", version: "2.4.68")
        let manifest = try fx.manifest([.init(component: "apache", branch: "2.4", version: "2.4.68", archive: archive)])
        let (installer, _) = makeInstaller(fx)

        let record = try await installer.install(component: "apache", branch: "2.4", from: manifest)
        #expect(record.extensions == nil)   // only PHP records extensions

        #expect(fm.isExecutableFile(atPath: fx.paths.package(component: "apache", version: "2.4.68")
            .appending(path: "bin/httpd").path(percentEncoded: false)))
        #expect(linkTarget(fx.paths.current(component: "apache", branch: "2.4")) == "../2.4.68")
    }

    @Test func internalRelativeSymlinksAllowed() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1", topLevelDir: "8.6.1",
                                     symlinks: ["bin/redis-cli": "redis-server", "lib/ver": "../share/VERSION"])
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive)])
        let (installer, _) = makeInstaller(fx)
        _ = try await installer.install(component: "redis", branch: "8.6", from: manifest)
        #expect(linkTarget(fx.paths.package(component: "redis", version: "8.6.1").appending(path: "bin/redis-cli"))
            == "redis-server")
    }

    // MARK: Fail closed

    @Test func checksumMismatchLeavesNothing() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35")
        let wrong = String(repeating: "0", count: 64)
        let manifest = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: archive,
                                              sha256Override: wrong)])
        let (installer, store) = makeInstaller(fx)

        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "php", branch: "8.3", from: manifest)
        }
        guard case .checksumMismatch(let component, let version, let expected, let actual)? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
        #expect(component == "php")
        #expect(version == "8.3.35")
        #expect(expected == wrong)
        #expect(actual == archive.sha256)
        #expect(error?.errorDescription?.contains(wrong) == true)
        try await expectNothingInstalled(fx, store, component: "php")
    }

    @Test func sizeMismatchLeavesNothing() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1")
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive,
                                              sizeOverride: archive.size + 1)])
        let (installer, store) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "redis", branch: "8.6", from: manifest)
        }
        guard case .sizeMismatch? = error else { Issue.record("wrong error \(String(describing: error))"); return }
        try await expectNothingInstalled(fx, store, component: "redis")
    }

    @Test(arguments: [",^,../,", ",^,/tmp/ramp-evil-abs/,"])
    func traversalEntriesRejectedBeforeExtraction(substitution: String) async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("php", version: "8.3.35", substitution: substitution)
        let manifest = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: archive)])
        let (installer, store) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "php", branch: "8.3", from: manifest)
        }
        guard case .unsafeArchive(let entry)? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
        #expect(entry.hasPrefix("../") || entry.hasPrefix("/"))
        #expect(!exists(URL(filePath: "/tmp/ramp-evil-abs")))
        #expect(!exists(fx.paths.root.appending(path: "sbin")))
        #expect(!exists(fx.paths.package(component: "php", version: "8.3.35")))
        #expect(contents(fx.paths.staging).isEmpty)
        #expect(try await store.load().installed.isEmpty)
    }

    @Test(arguments: [["lib/evil": "/etc"], ["lib/evil": "../../../outside"], ["evil": ".."]])
    func escapingSymlinksRejected(links: [String: String]) async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35", symlinks: links)
        let manifest = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: archive)])
        let (installer, store) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "php", branch: "8.3", from: manifest)
        }
        guard case .unsafeArchive? = error else { Issue.record("wrong error \(String(describing: error))"); return }
        #expect(!exists(fx.paths.package(component: "php", version: "8.3.35")))
        #expect(contents(fx.paths.staging).isEmpty)
        #expect(try await store.load().installed.isEmpty)
    }

    @Test(arguments: [("php", "8.3"), ("apache", "2.4"), ("mysql", "9.7"), ("redis", "8.6"), ("phpmyadmin", "5.2")])
    func missingSanityFileIsInvalidPackage(component: String, branch: String) async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let version = branch + ".1"
        let archive = try fx.package(component, version: version, topLevelDir: version, omitSanity: true)
        let manifest = try fx.manifest([.init(component: component, branch: branch, version: version, archive: archive)])
        let (installer, store) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: component, branch: branch, from: manifest)
        }
        guard case .invalidPackage? = error else { Issue.record("wrong error \(String(describing: error))"); return }
        #expect(!exists(fx.paths.package(component: component, version: version)))
        #expect(contents(fx.paths.staging).isEmpty)
        #expect(try await store.load().installed.isEmpty)
    }

    @Test func gzipArchiveInstalls() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1", topLevelDir: "8.6.1", compression: .gzip)
        #expect(archive.fileName.hasSuffix(".tar.gz"))
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive)])
        let (installer, _) = makeInstaller(fx)
        _ = try await installer.install(component: "redis", branch: "8.6", from: manifest)
        #expect(fm.isExecutableFile(atPath: fx.paths.current(component: "redis", branch: "8.6")
            .appending(path: "bin/redis-server").path(percentEncoded: false)))
    }

    @Test func xzFixturesAreRealXz() throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("php", version: "8.3.35")
        #expect(archive.fileName.hasSuffix(".tar.xz"))
        #expect(try ArchiveExtractor.format(of: archive.url) == .xz)
    }

    /// Only xz/gzip are accepted (by magic bytes, not name); e.g. uncompressed or zstd tarballs fail closed.
    @Test func unsupportedArchiveFormatFailsClosed() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1", compression: .none, name: "redis-8.6.1.tar.xz")
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive)])
        let (installer, store) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "redis", branch: "8.6", from: manifest)
        }
        guard case .unsupportedArchiveFormat? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
        #expect(!exists(fx.paths.root.appending(path: "redis")))
        #expect(contents(fx.paths.staging).isEmpty)
        #expect(try await store.load().installed.isEmpty)
    }

    /// 06-03: elasticsearch is installable on demand, but only with its sanity file (bin/elasticsearch).
    @Test func elasticsearchRequiresSanityFile() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("elasticsearch", version: "9.5.4")
        let manifest = try fx.manifest([.init(component: "elasticsearch", branch: "9.5", version: "9.5.4", archive: archive)])
        let (installer, _) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "elasticsearch", branch: "9.5", from: manifest)
        }
        guard case .invalidPackage? = error else { Issue.record("wrong error \(String(describing: error))"); return }
    }

    @Test func unknownBranchIsNotInManifest() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let manifest = try fx.manifest([])
        let (installer, _) = makeInstaller(fx)
        let error = await #expect(throws: InstallError.self) {
            try await installer.install(component: "php", branch: "9.9", from: manifest)
        }
        guard case .notInManifest? = error else { Issue.record("wrong error \(String(describing: error))"); return }
    }

    // MARK: Idempotence + upgrades

    @Test func reinstallSameVersionIsNoOp() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1", topLevelDir: "8.6.1")
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive)])
        let (installer, _) = makeInstaller(fx)
        let first = try await installer.install(component: "redis", branch: "8.6", from: manifest)

        // Source gone: a second install must not need it.
        try fm.removeItem(at: archive.url)
        let second = try await installer.install(component: "redis", branch: "8.6", from: manifest)
        #expect(second == first)  // same installedAt → existing record returned
    }

    @Test func cachedDownloadIsReusedWhenShaMatches() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let archive = try fx.package("redis", version: "8.6.1", topLevelDir: "8.6.1")
        let manifest = try fx.manifest([.init(component: "redis", branch: "8.6", version: "8.6.1", archive: archive)])
        let (installer, _) = makeInstaller(fx)
        _ = try await installer.install(component: "redis", branch: "8.6", from: manifest)
        #expect(exists(fx.paths.downloads.appending(path: archive.fileName)))

        // Forget the install (ramp.json + package dir), remove the source: cached download must suffice.
        try fm.removeItem(at: fx.paths.configFile)
        try fm.removeItem(at: fx.paths.root.appending(path: "redis"))
        try fm.removeItem(at: archive.url)
        let record = try await installer.install(component: "redis", branch: "8.6", from: manifest)
        #expect(record.version == "8.6.1")
        #expect(linkTarget(fx.paths.current(component: "redis", branch: "8.6")) == "../8.6.1")
    }

    @Test func newerVersionSwitchesCurrentAndKeepsOld() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let old = try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35")
        let new = try fx.package("php", version: "8.3.36", topLevelDir: "8.3.36")
        let (installer, store) = makeInstaller(fx)

        let m1 = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.35", archive: old)])
        _ = try await installer.install(component: "php", branch: "8.3", from: m1)
        let m2 = try fx.manifest([.init(component: "php", branch: "8.3", version: "8.3.36", archive: new)])
        let record = try await installer.install(component: "php", branch: "8.3", from: m2)

        #expect(record.version == "8.3.36")
        #expect(linkTarget(fx.paths.current(component: "php", branch: "8.3")) == "../8.3.36")
        #expect(exists(fx.paths.package(component: "php", version: "8.3.35").appending(path: "sbin/php-fpm")))
        #expect(exists(fx.paths.package(component: "php", version: "8.3.36").appending(path: "sbin/php-fpm")))
        #expect(try await store.load().installed["php"]?["8.3"]?.version == "8.3.36")
        // No leftover temp symlinks next to `current`.
        #expect(contents(fx.paths.branchDir(component: "php", branch: "8.3")) == ["current"])
    }

    // MARK: Default set

    @Test func defaultSetCollectsFailuresAndReportsProgress() async throws {
        let fx = try FixtureBuilder(); defer { fx.cleanup() }
        let entries: [FixtureBuilder.Entry] = [
            .init(component: "apache", branch: "2.4", version: "2.4.68", archive: try fx.package("apache", version: "2.4.68")),
            .init(component: "redis", branch: "8.6", version: "8.6.1", archive: try fx.package("redis", version: "8.6.1")),
            .init(component: "mysql", branch: "9.7", version: "9.7.3", archive: try fx.package("mysql", version: "9.7.3")),
            .init(component: "mysql", branch: "8.4", version: "8.4.12", archive: try fx.package("mysql", version: "8.4.12")),
            .init(component: "phpmyadmin", branch: "5.2", version: "5.2.3",
                  archive: try fx.package("phpmyadmin", version: "5.2.3")),
            .init(component: "php", branch: "8.3", version: "8.3.35",
                  archive: try fx.package("php", version: "8.3.35", topLevelDir: "8.3.35")),
            .init(component: "php", branch: "8.4", version: "8.4.20",
                  archive: try fx.package("php", version: "8.4.20"), sha256Override: String(repeating: "f", count: 64)),
            .init(component: "php", branch: "8.5", version: "8.5.5", archive: try fx.package("php", version: "8.5.5")),
        ]
        let manifest = try fx.manifest(entries)
        let (installer, store) = makeInstaller(fx)

        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let collector = Task { () -> [InstallProgress] in
            var events: [InstallProgress] = []
            for await e in stream { events.append(e) }
            return events
        }
        let report = await installer.installDefaultSet(manifest, progress: continuation)
        let events = await collector.value  // stream finished by the installer

        let installedKeys = Set(report.installed.keys.map { "\($0.component)/\($0.branch)" })
        #expect(installedKeys == ["apache/2.4", "redis/8.6", "mysql/9.7", "phpmyadmin/5.2", "php/8.3", "php/8.5"])
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.component == "php")
        #expect(report.failures.first?.branch == "8.4")
        #expect(!report.succeeded)

        let installed = try await store.load().installed
        #expect(installed["mysql"]?["8.4"] == nil)
        #expect(installed["php"]?.keys.sorted() == ["8.3", "8.5"])

        #expect(events.contains { $0.component == "php" && $0.branch == "8.4" && { if case .failed = $0.stage { true } else { false } }($0) })
        #expect(events.filter { if case .installed = $0.stage { true } else { false } }.count == 6)
        #expect(events.contains { $0.component == "apache" && $0.stage == .downloading })
        // Byte progress: the finished download is reported as complete (bytes == total).
        let apacheBytes = events.compactMap { $0.component == "apache" ? $0.download : nil }
        #expect(apacheBytes.last.map { $0.bytesReceived > 0 && $0.fraction == 1 } == true)
    }
}
