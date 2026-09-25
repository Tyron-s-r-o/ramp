import CryptoKit
import Darwin
import Foundation

public enum ComposerError: Error, LocalizedError, Equatable {
    case download(String)
    case checksumFormat(String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .download(let why): return "Composer download failed: \(why)"
        case .checksumFormat(let text): return "Unexpected composer.phar.sha256sum content: \(text.prefix(80))"
        case .checksumMismatch(let e, let a): return "composer.phar sha256 mismatch (expected \(e), got \(a))"
        }
    }
}

/// Composer 2 latest stable (`getcomposer.org`), verified against the published sha256 and stored as
/// `<root>/composer/composer.phar`. Refreshed by "cli update" (app / rampctl) or when older than a week.
public struct ComposerInstaller: Sendable {
    public static let pharURL = URL(string: "https://getcomposer.org/download/latest-stable/composer.phar")!
    public static let checksumURL = URL(string: "https://getcomposer.org/download/latest-stable/composer.phar.sha256sum")!
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    public let paths: Paths
    public let pharURL: URL
    public let checksumURL: URL
    public let session: URLSession

    public init(paths: Paths, pharURL: URL = ComposerInstaller.pharURL,
                checksumURL: URL = ComposerInstaller.checksumURL, session: URLSession = .shared) {
        self.paths = paths
        self.pharURL = pharURL
        self.checksumURL = checksumURL
        self.session = session
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: ConfigText.path(paths.composerPhar)) }

    /// Last download (file mtime), nil when missing.
    public var installedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: ConfigText.path(paths.composerPhar)))?[.modificationDate] as? Date
    }

    /// Missing or older than `maxAge`.
    public func needsRefresh(now: Date = Date()) -> Bool {
        guard let at = installedAt else { return true }
        return now.timeIntervalSince(at) > Self.maxAge
    }

    /// Downloads + verifies + atomically replaces composer.phar. Returns the sha256.
    @discardableResult
    public func update() async throws -> String {
        let sumText = String(decoding: try await fetch(checksumURL), as: UTF8.self)
        let expected = try Self.parseChecksum(sumText)
        let data = try await fetch(pharURL)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw ComposerError.checksumMismatch(expected: expected, actual: actual) }

        let fm = FileManager.default
        try fm.createDirectory(at: paths.composerDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let target = ConfigText.path(paths.composerPhar)
        let temp = ConfigText.path(paths.composerDir) + "/.composer.phar.tmp-\(UUID().uuidString)"
        guard fm.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o755]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp])
        }
        if rename(temp, target) != 0 {
            let err = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return actual
    }

    /// Hex sha256 of a local file.
    public static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

        /// `"<64 hex>  composer.phar"` → hex.
    public static func parseChecksum(_ text: String) throws -> String {
        guard let first = text.split(whereSeparator: \.isWhitespace).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else {
            throw ComposerError.checksumFormat(text)
        }
        return first.lowercased()
    }

    private func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL {
            do { return try Data(contentsOf: url) } catch { throw ComposerError.download("\(url): \(error.localizedDescription)") }
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ComposerError.download("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            return data
        } catch let error as ComposerError {
            throw error
        } catch {
            throw ComposerError.download(error.localizedDescription)
        }
    }
}

/// Terminal integration facade used by the app and rampctl: CLI php.ini files + `~/.ramp/bin` shims
/// (`syncShims`), PATH block / MAMP lines (`shell`), Composer (`composer`).
public struct CLIIntegration: Sendable {
    public let paths: Paths
    public let shell: ShellIntegration

    public init(paths: Paths, home: URL = ShellIntegration.standardHome()) {
        self.paths = paths
        self.shell = ShellIntegration(home: home)
    }

    public var shimDir: URL { shell.shimDir }

    /// Automatic shim syncs (app launch, `rampctl up`, `rampctl php enable`) only for the standard layout, or
    /// when `HOME` is a sandbox too — a dev `RAMP_HOME` must never rewrite the real `~/.ramp/bin`.
    public static func automaticSyncAllowed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let rampHome = environment["RAMP_HOME"], !rampHome.isEmpty else { return true }
        let home = ShellIntegration.standardHome(environment: environment)
        return UninstallPathGuard.canonical(home.path(percentEncoded: false))
            != UninstallPathGuard.canonical(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
    }

    /// Home for `StackController(cliHome:)`: nil when automatic syncs are not allowed.
    public static func automaticHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        automaticSyncAllowed(environment: environment) ? ShellIntegration.standardHome(environment: environment) : nil
    }
    public var composer: ComposerInstaller { ComposerInstaller(paths: paths) }

    /// Writes every enabled branch's `php-cli.ini` (branches whose ini cannot be rendered get no shims), then
    /// syncs the shims (stale managed ones removed, foreign files untouched).
    @discardableResult
    public func syncShims(config: RampConfig) throws -> CLIShimWriter.Report {
        var effective = config
        let generator = PHPIniGenerator(config: config, paths: paths)
        var files: [GeneratedFile] = []
        for branch in CLIShimGenerator.phpBranches(config) {
            if let file = try? generator.cliIni(branch: branch) {
                files.append(file)
            } else {
                effective.php.branches[branch, default: PHPBranchSettings()].enabled = false
            }
        }
        try ConfigWriter(paths: paths).write(files)
        let shims = CLIShimGenerator(config: effective, paths: paths, shimDir: shimDir).shims()
        return try CLIShimWriter(shimDir: shimDir).sync(shims)
    }

    /// Removes the managed shims, then `~/.ramp/bin` and `~/.ramp` when empty.
    @discardableResult
    public func removeShims() -> [String] {
        let removed = CLIShimWriter(shimDir: shimDir).removeAll()
        rmdir(ConfigText.path(shimDir))
        rmdir(ConfigText.path(shell.rampDir))
        return removed
    }

    public func commandNames(config: RampConfig) -> [String] {
        CLIShimGenerator(config: config, paths: paths, shimDir: shimDir).commandNames()
    }
}
