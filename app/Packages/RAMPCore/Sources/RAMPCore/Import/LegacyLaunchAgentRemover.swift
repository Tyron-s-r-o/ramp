import Darwin
import Foundation

/// A user LaunchAgent that drives a standalone Elasticsearch (e.g. `com.rv.elastic-autostop`), plan 07-05.
public struct LegacyAgent: Sendable, Equatable, Codable, Hashable {
    public var label: String
    public var plistURL: URL
    public var programArguments: [String]

    public init(label: String, plistURL: URL, programArguments: [String]) {
        self.label = label
        self.plistURL = plistURL
        self.programArguments = programArguments
    }

    /// First argument that points into the ES dir (the script), for display.
    public func scriptPath(in esDir: URL) -> String? {
        programArguments.first { LegacyLaunchAgentRemover.references($0, esDir) }
    }
}

public enum LegacyLaunchAgentError: Error, LocalizedError, Equatable {
    case notConfirmed
    case changed(String)
    case bootoutFailed(status: Int32, output: String)
    case trashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Removing the LaunchAgent needs explicit confirmation"
        case .changed(let why): return "The LaunchAgent changed since it was detected: \(why)"
        case .bootoutFailed(let status, let output):
            return "launchctl bootout failed (exit \(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .trashFailed(let message): return "Cannot move the plist to the Trash: \(message)"
        }
    }
}

/// Finds and removes the legacy ES auto-stop LaunchAgent. Removal = `launchctl bootout gui/<uid>/<label>` (not loaded
/// is fine) + plist moved to the Trash — callers must gate it behind an explicit confirmation. `launchctl` runner,
/// LaunchAgents dir and trash action are injectable (tests never touch the real ones).
public struct LegacyLaunchAgentRemover: Sendable {
    public typealias TrashAction = @Sendable (URL) throws -> URL?

    public let launchAgentsDir: URL
    public let runner: any ProcessRunning
    public let uid: uid_t
    public let trash: TrashAction
    public let launchctl: String

    public init(launchAgentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
                runner: any ProcessRunning = SystemProcessRunner(tempDir: FileManager.default.temporaryDirectory),
                uid: uid_t = getuid(),
                launchctl: String = "/bin/launchctl",
                trash: TrashAction? = nil) {
        self.launchAgentsDir = launchAgentsDir
        self.runner = runner
        self.uid = uid
        self.launchctl = launchctl
        self.trash = trash ?? { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    }

    /// Agents whose label looks like an Elasticsearch helper (contains "elastic", never RAMP's own `sk.tyron.*`) and
    /// whose `Program`/`ProgramArguments` reference `esDir`.
    public func find(referencing esDir: URL) -> [LegacyAgent] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: launchAgentsDir.path(percentEncoded: false)) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            Self.parse(launchAgentsDir.appending(path: name, directoryHint: .notDirectory), esDir: esDir)
        }
    }

    static func parse(_ url: URL, esDir: URL) -> LegacyAgent? {
        var st = stat()
        // Regular files only (a symlink could point anywhere).
        guard lstat(url.path(percentEncoded: false), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let lower = label.lowercased()
        guard lower.contains("elastic"), !lower.hasPrefix("sk.tyron") else { return nil }
        var args = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String, !args.contains(program) { args.insert(program, at: 0) }
        guard args.contains(where: { references($0, esDir) }) else { return nil }
        return LegacyAgent(label: label, plistURL: url, programArguments: args)
    }

    /// `arg` is `esDir` or a path inside it (component-wise, `…/elasticsearch-9.5.40` ≠ `…/elasticsearch-9.5.4`).
    static func references(_ arg: String, _ esDir: URL) -> Bool {
        let base = esDir.standardizedFileURL.path(percentEncoded: false).trimmingSlash
        let path = (arg as NSString).expandingTildeInPath
        return path == base || path.hasPrefix(base + "/")
    }

    /// `launchctl bootout gui/<uid>/<label>` (exit 3 / 113 / "not find" = not loaded → OK) → plist to the Trash.
    /// Re-validates the plist first (still a regular file in the LaunchAgents dir with the same label).
    /// Returns the trashed URL (nil when the trash action does not report one).
    @discardableResult
    public func remove(_ agent: LegacyAgent, referencing esDir: URL, confirmed: Bool) async throws -> URL? {
        guard confirmed else { throw LegacyLaunchAgentError.notConfirmed }
        let dir = launchAgentsDir.standardizedFileURL.path(percentEncoded: false).trimmingSlash
        guard agent.plistURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false).trimmingSlash == dir
        else { throw LegacyLaunchAgentError.changed("plist is not in \(dir)") }
        guard let fresh = Self.parse(agent.plistURL, esDir: esDir), fresh.label == agent.label else {
            throw LegacyLaunchAgentError.changed("label or program no longer matches")
        }
        let result = await runner.run([launchctl, "bootout", "gui/\(uid)/\(agent.label)"], environment: [:],
                                      timeout: .seconds(30))
        let notLoaded = result.status == 3 || result.status == 113
            || result.output.localizedCaseInsensitiveContains("could not find")
            || result.output.localizedCaseInsensitiveContains("no such process")
        guard result.status == 0 || notLoaded else {
            throw LegacyLaunchAgentError.bootoutFailed(status: result.status, output: result.output)
        }
        do {
            return try trash(agent.plistURL)
        } catch {
            throw LegacyLaunchAgentError.trashFailed(error.localizedDescription)
        }
    }
}
