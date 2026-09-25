import Darwin
import Foundation

/// `/tmp/mysql.sock` compatibility symlink → RAMP's active MySQL socket (`<root>/run/mysql<branch>.sock`).
///
/// The `mysql` client (and PHP CLI / 3rd-party scripts) compiled with the default socket connect to
/// `/tmp/mysql.sock` when neither `--socket` nor `--host` is given. RAMP creates the link while MySQL runs
/// and removes it on stop. Foreign files (another MySQL's real socket, a symlink elsewhere) are never
/// touched — only a symlink pointing into this RAMP's `run/` directory counts as RAMP's own.
public struct MySQLTmpSocketLink: Sendable, Equatable {
    public static let defaultPath = URL(filePath: "/tmp/mysql.sock", directoryHint: .notDirectory)
    /// Environment override of the link path (dev / integration sandboxes); empty value = disabled.
    public static let environmentKey = "RAMP_TMP_MYSQL_SOCK"

    /// What currently occupies the link path.
    public enum Existing: Sendable, Equatable {
        case missing
        /// A symlink; `destination` is absolute (relative destinations resolved against the link's directory).
        case symlink(destination: String)
        /// Anything else: a real socket, file or directory ("socket" / "file" / "directory" / "other").
        case other(kind: String)
    }

    /// Decision for "MySQL is ready, make the link point to `target`".
    public enum EnsureAction: Sendable, Equatable {
        case create
        /// Our own link, pointing to an old target (branch changed / stale).
        case replace(old: String)
        /// Our own link, already correct.
        case keep
        /// Not ours — leave it alone (warning).
        case leaveForeign(String)
    }

    public enum Outcome: Sendable, Equatable {
        case created(target: String)
        case replaced(old: String, new: String)
        case unchanged
        case removed(old: String)
        /// Nothing at the link path, nothing to remove.
        case absent
        /// A foreign file was left alone.
        case skippedForeign(String)
        case failed(String)

        /// Text for the MySQL log; nil when the outcome needs no attention.
        public var warning: String? {
            switch self {
            case .skippedForeign(let what): return "left alone (not RAMP's): \(what)"
            case .failed(let why): return "failed: \(why)"
            default: return nil
            }
        }
    }

    public let linkPath: URL
    public let runDir: URL

    public init(linkPath: URL = MySQLTmpSocketLink.defaultPath, paths: Paths) {
        self.linkPath = linkPath
        self.runDir = paths.runDir
    }

    /// Link path from the environment: default `/tmp/mysql.sock`, `RAMP_TMP_MYSQL_SOCK=<path>` overrides,
    /// `RAMP_TMP_MYSQL_SOCK=` (empty) disables the link (nil).
    public static func standardPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let value = environment[environmentKey] else { return defaultPath }
        return value.isEmpty ? nil : URL(filePath: (value as NSString).expandingTildeInPath, directoryHint: .notDirectory)
    }

    // MARK: Pure decisions

    public static func ensureAction(existing: Existing, target: String, runDir: String) -> EnsureAction {
        switch existing {
        case .missing:
            return .create
        case .symlink(let destination):
            guard isInside(destination, runDir: runDir) else {
                return .leaveForeign("symlink → \(destination)")
            }
            return normalize(destination) == normalize(target) ? .keep : .replace(old: destination)
        case .other(let kind):
            return .leaveForeign(kind)
        }
    }

    /// Only a symlink into RAMP's `run/` is removed.
    public static func shouldRemove(existing: Existing, runDir: String) -> Bool {
        if case .symlink(let destination) = existing { return isInside(destination, runDir: runDir) }
        return false
    }

    /// `path` lies strictly under `runDir` (component-wise, `..` resolved; also compared with symlinks
    /// such as /tmp → /private/tmp resolved).
    public static func isInside(_ path: String, runDir: String) -> Bool {
        func under(_ p: String, _ dir: String) -> Bool {
            let c = (p as NSString).pathComponents, d = (dir as NSString).pathComponents
            return c.count > d.count && Array(c.prefix(d.count)) == d
        }
        if under(normalize(path), normalize(runDir)) { return true }
        return under(resolved(path), resolved(runDir))
    }

    private static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private static func resolved(_ path: String) -> String {
        URL(filePath: normalize(path)).resolvingSymlinksInPath().path(percentEncoded: false)
    }

    // MARK: Filesystem

    private var linkPathString: String { linkPath.path(percentEncoded: false) }
    private var runDirString: String { runDir.path(percentEncoded: false) }

    public func inspect() -> Existing {
        var st = stat()
        guard lstat(linkPathString, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPathString) else {
                return .other(kind: "unreadable symlink")
            }
            let absolute = raw.hasPrefix("/") ? raw
                : (linkPath.deletingLastPathComponent().path(percentEncoded: false) as NSString).appendingPathComponent(raw)
            return .symlink(destination: absolute)
        case S_IFSOCK: return .other(kind: "socket")
        case S_IFREG: return .other(kind: "file")
        case S_IFDIR: return .other(kind: "directory")
        default: return .other(kind: "other")
        }
    }

    /// Points the link at `target` when the path is free or already RAMP's; foreign files are left alone.
    @discardableResult
    public func ensure(target: URL) -> Outcome {
        let targetPath = target.path(percentEncoded: false)
        switch Self.ensureAction(existing: inspect(), target: targetPath, runDir: runDirString) {
        case .keep:
            return .unchanged
        case .leaveForeign(let what):
            return .skippedForeign("\(linkPathString): \(what)")
        case .create:
            guard symlink(targetPath, linkPathString) == 0 else {
                return .failed("symlink \(linkPathString) → \(targetPath): \(String(cString: strerror(errno)))")
            }
            return .created(target: targetPath)
        case .replace(let old):
            // Atomic swap: temp link in the same directory, rename(2) over the old link.
            let temp = linkPath.deletingLastPathComponent()
                .appending(path: ".\(linkPath.lastPathComponent).ramp-\(getpid())", directoryHint: .notDirectory)
                .path(percentEncoded: false)
            unlink(temp)
            guard symlink(targetPath, temp) == 0 else {
                return .failed("symlink \(temp) → \(targetPath): \(String(cString: strerror(errno)))")
            }
            guard rename(temp, linkPathString) == 0 else {
                let why = String(cString: strerror(errno))
                unlink(temp)
                return .failed("replace \(linkPathString): \(why)")
            }
            return .replaced(old: old, new: targetPath)
        }
    }

    /// Removes the link only if it points into RAMP's `run/`.
    @discardableResult
    public func removeIfOwned() -> Outcome {
        let existing = inspect()
        switch existing {
        case .missing:
            return .absent
        case .symlink(let destination) where Self.shouldRemove(existing: existing, runDir: runDirString):
            guard unlink(linkPathString) == 0 else {
                return .failed("unlink \(linkPathString): \(String(cString: strerror(errno)))")
            }
            return .removed(old: destination)
        case .symlink(let destination):
            return .skippedForeign("\(linkPathString): symlink → \(destination)")
        case .other(let kind):
            return .skippedForeign("\(linkPathString): \(kind)")
        }
    }

    /// One-line state for `rampctl status` / `paths`. `expectedTarget` = socket of the running MySQL, if any.
    public func describe(expectedTarget: URL?) -> String {
        switch inspect() {
        case .missing:
            return "absent"
        case .symlink(let destination):
            guard Self.isInside(destination, runDir: runDirString) else {
                return "symlink → \(destination) (not RAMP's, left alone)"
            }
            var text = "symlink → \(destination) (RAMP)"
            if !FileManager.default.fileExists(atPath: destination) { text += ", dangling" }
            if let expected = expectedTarget?.path(percentEncoded: false),
               Self.normalize(expected) != Self.normalize(destination) {
                text += ", expected \(expected)"
            }
            return text
        case .other(let kind):
            return "\(kind) (not RAMP's, left alone)"
        }
    }
}
