import Foundation
@testable import RAMPCore

/// Shared fixture for generator tests (plan 02-03):
/// root with a space, php 7.3/8.2/8.3/8.5, apache 2.4.68, mysql 9.7.3, redis 8.10.2.
enum GeneratorFixture {
    static let rootPath = "/Users/t/Library/Application Support/RAMP"
    static let logsPath = "/Users/t/Library/Logs/RAMP"

    static let paths = Paths(
        root: URL(filePath: rootPath, directoryHint: .isDirectory),
        logs: URL(filePath: logsPath, directoryHint: .isDirectory)
    )

    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func pkg(_ version: String, ext: String? = nil) -> InstalledPackage {
        InstalledPackage(version: version, sha256: "00", installedAt: date, extensionDirRel: ext)
    }

    static let extRel = "lib/php/extensions/no-debug-non-zts-20240924"

    static var config: RampConfig {
        RampConfig(
            installed: [
                "php": [
                    "7.3": pkg("7.3.33", ext: "lib/php/extensions/no-debug-non-zts-20180731"),
                    "8.2": pkg("8.2.30", ext: "lib/php/extensions/no-debug-non-zts-20220829"),
                    "8.3": pkg("8.3.35", ext: "lib/php/extensions/no-debug-non-zts-20230831"),
                    "8.5": pkg("8.5.5", ext: extRel),
                ],
                "apache": ["2.4": pkg("2.4.68")],
                "mysql": ["9.7": pkg("9.7.3")],
                "redis": ["8.10": pkg("8.10.2")],
            ],
            apache: ApacheSettings(port: 8080)
        )
    }
}
