import Foundation
@testable import RAMPCore

/// In-memory filesystem for the validator: explicit kinds + symlinks (path → target).
struct FakeFileChecking: FileChecking {
    var kinds: [String: FileKind] = [:]
    var symlinks: [String: String] = [:]

    func kind(at path: String) -> FileKind {
        guard let resolved = realpath(path) else { return .missing }
        return kinds[resolved] ?? .missing
    }

    func realpath(_ path: String) -> String? {
        let resolved = symlinks[path] ?? path
        return kinds[resolved] == nil ? nil : resolved
    }
}

enum VhostFixtures {
    static let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    static let paths = Paths(
        root: URL(filePath: "/Users/tester/Library/Application Support/RAMP", directoryHint: .isDirectory),
        logs: URL(filePath: "/Users/tester/Library/Logs/RAMP", directoryHint: .isDirectory))

    static let installed = InstalledPackage(version: "x", sha256: "x", installedAt: Date(timeIntervalSince1970: 0))

    /// Config with PHP 7.3 / 8.1 / 8.2 / 8.3 installed and no vhosts.
    static func baseConfig(php: [String] = ["7.3", "8.1", "8.2", "8.3"]) -> RampConfig {
        var config = RampConfig()
        config.installed["php"] = Dictionary(uniqueKeysWithValues: php.map { ($0, installed) })
        return config
    }

    static let ids = (0..<5).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }

    /// Mirrors the MAMP setup (plan/03-mamp-analysis.md).
    static func mampVhosts() -> [Vhost] {
        [
            Vhost(id: ids[0], domain: "asteel.local", aliases: ["admin.asteel.local"],
                  docroot: "/Users/tester/Sites/asteel/www"),
            Vhost(id: ids[1], domain: "front.asteel.local",
                  aliases: ["sk.asteel.local", "cz.asteel.local", "hu.asteel.local",
                            "pl.asteel.local", "ro.asteel.local", "at.asteel.local"],
                  docroot: "/Users/tester/Sites/asteel-front/public"),
            Vhost(id: ids[2], domain: "tyrestock.local", docroot: "/Users/tester/Sites/tyrestock/www", phpBranch: "8.2"),
            Vhost(id: ids[3], domain: "tyrefleet.local", docroot: "/Users/tester/Sites/tyrefleet/www", phpBranch: "7.3"),
            Vhost(id: ids[4], domain: "pneuprofi.local", docroot: "/Users/tester/Sites/pneuprofi/www", phpBranch: "8.1"),
        ]
    }

    static func mampFS() -> FakeFileChecking {
        var fs = FakeFileChecking()
        for v in mampVhosts() { fs.kinds[v.docroot] = .directory }
        return fs
    }

    static func mampConfig() -> RampConfig {
        var config = baseConfig()
        config.vhosts = mampVhosts()
        return config
    }

    static func validator(_ config: RampConfig, fs: FakeFileChecking) -> VhostValidator {
        VhostValidator(config: config, paths: paths, fs: fs, home: home)
    }

    static func catalog(fs: FakeFileChecking) -> VhostCatalog {
        VhostCatalog(paths: paths, fs: fs, home: home)
    }
}
