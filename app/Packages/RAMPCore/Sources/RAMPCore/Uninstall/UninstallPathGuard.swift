import Darwin
import Foundation

/// Why an uninstall (or one of its paths) was refused / failed.
public enum UninstallError: Error, Equatable, LocalizedError, Sendable {
    case emptyPath
    case relativePath(String)
    /// `.` / `..` components are never accepted (lexical vs. physical resolution differ behind symlinks).
    case dotComponents(String)
    /// The parent directory cannot be resolved (does not exist / unreadable).
    case unresolvable(String)
    case outsideAllowedRoots(String)
    /// Equal to / ancestor of a protected directory (home, ~/Library, project docroot, …) or inside a project tree.
    case protected(String)
    /// `RAMP_HOME` / `RAMP_LOGS` point somewhere RAMP must never delete.
    case unsafeRoot(String)
    case busy(String)
    case dumpFailed(String)
    case planNotExecutable([String])

    public var errorDescription: String? {
        switch self {
        case .emptyPath: return "Empty path"
        case .relativePath(let p): return "Relative path refused: \(p)"
        case .dotComponents(let p): return "Path with '.' or '..' refused: \(p)"
        case .unresolvable(let p): return "Cannot resolve parent directory of \(p)"
        case .outsideAllowedRoots(let p): return "Not a RAMP-owned path: \(p)"
        case .protected(let p): return "Protected path (home, Library, project folder or its ancestor): \(p)"
        case .unsafeRoot(let p): return "Unsafe RAMP data/log directory, refusing to delete it: \(p)"
        case .busy(let why): return "Another maintenance task is running: \(why)"
        case .dumpFailed(let why): return "Database backup failed, nothing was deleted: \(why)"
        case .planNotExecutable(let reasons): return "Uninstall refused:\n" + reasons.joined(separator: "\n")
        }
    }
}

/// The only gate between uninstall and `removeItem`. A path may be deleted iff it is RAMP-owned:
/// strictly inside (component-wise) or equal to `<library>/Application Support/RAMP`, `<library>/Logs/RAMP`,
/// `<library>/Caches/<bundleID>`, `<library>/HTTPStorages/<bundleID>`, `<home>/.ramp` (terminal shims),
/// a safe custom `Paths.root/logs`,
/// or exactly `<library>/Preferences/<bundleID>.plist` — and it is neither equal to nor an ancestor of any
/// denied root, nor inside a project tree (docroots, ~/Sites, ~/Desktop, ~/Documents).
///
/// Resolution: the *parent* is resolved with `realpath` (symlinks followed), the last component is kept
/// as is — a symlink item is therefore judged (and later removed) as the link itself, never its target.
public struct UninstallPathGuard: Sendable {
    public let home: URL
    public let library: URL
    public let bundleID: String
    /// Canonical allowed roots (deletable themselves and everything below).
    public let allowedRoots: [String]
    /// Canonical preferences plist (exact match only).
    public let preferencesFile: String
    /// Canonical denied roots: equal-or-ancestor is refused.
    public let deniedRoots: [String]
    /// Canonical denied roots whose whole subtree is refused too (everything except home and ~/Library).
    public let protectedTrees: [String]
    /// Custom `RAMP_HOME`/`RAMP_LOGS` that were refused (explanations). Non-empty → the plan is not executable.
    public let refusedRoots: [String]

    /// Minimum depth of a home directory (`/Users/x` = 2) — `/` or `/Users` as "home" disables every root.
    static let minHomeDepth = 2
    /// Custom roots must be at least this many components below home (`~/dev/ramp`).
    static let minCustomDepthBelowHome = 2

    public init(home: URL, library: URL, paths: Paths, bundleID: String, deniedRoots: [URL]) {
        let homeC = Self.canonical(home.path(percentEncoded: false))
        let libC = Self.canonical(library.path(percentEncoded: false))
        self.home = home
        self.library = library
        self.bundleID = bundleID

        var denied = deniedRoots.map { Self.canonical($0.path(percentEncoded: false)) }
        denied += ["/", homeC, libC]
        let deniedSet = Array(Set(denied)).sorted()
        self.deniedRoots = deniedSet

        let homeOK = Self.components(homeC).count >= Self.minHomeDepth && !bundleID.isEmpty
            && !bundleID.contains("/") && bundleID != "." && bundleID != ".."
            && Self.isInside(libC, homeC)
        var standard: [String] = []
        if homeOK {
            for sub in ["Application Support/RAMP", "Logs/RAMP", "Caches/\(bundleID)", "HTTPStorages/\(bundleID)"] {
                standard += Self.forms(of: library.appending(path: sub, directoryHint: .isDirectory))
            }
            // Terminal shims (`ShellIntegration.rampDir`).
            standard += Self.forms(of: home.appending(path: ".ramp", directoryHint: .isDirectory))
        }
        // A denied root is a whole protected tree unless it is home/Library or contains a standard RAMP root
        // (e.g. ~/Library/Application Support): then only equal-or-ancestor is refused.
        let trees = deniedSet.filter { d in
            d != "/" && d != homeC && d != libC && !standard.contains { $0 == d || Self.isInside($0, d) }
        }
        protectedTrees = trees

        var allowed = standard
        var refused: [String] = []
        if homeOK {
            preferencesFile = Self.parentCanonical(
                library.appending(path: "Preferences/\(bundleID).plist", directoryHint: .notDirectory)
                    .path(percentEncoded: false)) ?? ""
            let standardRoots = Set(standard)
            for (label, url) in [("RAMP_HOME", paths.root), ("RAMP_LOGS", paths.logs)] {
                let forms = Self.forms(of: url)
                if forms.allSatisfy({ standardRoots.contains($0) }) { continue }
                if let why = Self.customRootProblem(forms: forms, home: homeC, library: libC, denied: deniedSet,
                                                    trees: trees) {
                    refused.append("\(label) \(url.path(percentEncoded: false)): \(why)")
                } else {
                    allowed += forms
                }
            }
        } else {
            preferencesFile = ""
            refused.append("home \(home.path(percentEncoded: false)) is not a valid user home directory")
        }
        allowedRoots = Array(Set(allowed)).sorted()
        refusedRoots = refused
    }

    /// Denied roots for a real install: `/`, home, `~/Library`, `~/Sites`, `~/Desktop`, `~/Documents` and
    /// every vhost docroot.
    public static func defaultDeniedRoots(home: URL, docroots: [String]) -> [URL] {
        var urls = [URL(filePath: "/", directoryHint: .isDirectory), home]
        for sub in ["Library", "Sites", "Desktop", "Documents", "Downloads", "Library/Application Support",
                    "Library/Logs", "Library/Preferences", "Library/Caches"] {
            urls.append(home.appending(path: sub, directoryHint: .isDirectory))
        }
        for doc in docroots where doc.hasPrefix("/") {
            urls.append(URL(filePath: doc, directoryHint: .isDirectory))
        }
        return urls
    }

    public func check(_ url: URL) -> Result<URL, UninstallError> {
        check(path: url.path(percentEncoded: false))
    }

    /// `.success(canonical URL)` — the URL every deletion must use — or the reason for refusal.
    public func check(path raw: String) -> Result<URL, UninstallError> {
        guard !raw.isEmpty else { return .failure(.emptyPath) }
        guard raw.hasPrefix("/") else { return .failure(.relativePath(raw)) }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return .failure(.dotComponents(raw)) }
        guard !parts.isEmpty else { return .failure(.protected("/")) }
        guard let resolved = Self.parentCanonical(raw) else { return .failure(.unresolvable(raw)) }

        for denied in deniedRoots where resolved == denied || Self.isInside(denied, resolved) {
            return .failure(.protected(raw))
        }
        // "link/" would make the kernel follow the link — judge (and remove) only the link itself.
        if raw.hasSuffix("/"), Self.isSymlink(raw) { return .failure(.protected(raw)) }
        if !preferencesFile.isEmpty && resolved == preferencesFile { return .success(URL(filePath: resolved)) }
        for tree in protectedTrees where Self.isInside(resolved, tree) {
            return .failure(.protected(raw))
        }
        let inAllowed = allowedRoots.contains { resolved == $0 || Self.isInside(resolved, $0) }
        guard inAllowed else { return .failure(.outsideAllowedRoots(raw)) }
        return .success(URL(filePath: resolved))
    }

    // MARK: - Path helpers (strings, no URL normalization surprises)

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `child` strictly inside `parent`, component-wise (`/a/RAMP2` is not inside `/a/RAMP`).
    static func isInside(_ child: String, _ parent: String) -> Bool {
        let c = components(child), p = components(parent)
        return c.count > p.count && Array(c.prefix(p.count)) == p
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return lstat(trimmed, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func join(_ comps: [String]) -> String { "/" + comps.joined(separator: "/") }

    /// Fully resolved path; for non-existing tails: realpath of the longest existing ancestor + rest.
    static func canonical(_ path: String) -> String {
        var comps = components(path).filter { $0 != "." }
        var tail: [String] = []
        while true {
            let candidate = join(comps)
            if let real = realpath(candidate, nil) {
                defer { free(real) }
                let base = components(String(cString: real))
                return join(base + tail)
            }
            guard let last = comps.popLast() else { return join(tail) }
            tail.insert(last, at: 0)
        }
    }

    /// realpath(parent) + last component (the item itself is not followed). `nil` if the parent is missing.
    static func parentCanonical(_ path: String) -> String? {
        var comps = components(path)
        guard let last = comps.popLast() else { return nil }
        guard let real = realpath(join(comps), nil) else { return nil }
        defer { free(real) }
        return join(components(String(cString: real)) + [last])
    }

    /// Both the fully-resolved form and the "link itself" form of a root (a root may be a symlink to
    /// another volume: its children resolve into the target, the root link itself stays in Library).
    static func forms(of url: URL) -> [String] {
        let path = url.path(percentEncoded: false)
        var result = [canonical(path)]
        if let p = parentCanonical(path) { result.append(p) }
        return Array(Set(result))
    }

    static func customRootProblem(forms: [String], home: String, library: String, denied: [String],
                                  trees: [String]) -> String? {
        for f in forms {
            guard isInside(f, home) else { return "not inside the home directory" }
            if f == library || isInside(f, library) { return "lies inside ~/Library (only RAMP's own folders there)" }
            if components(f).count - components(home).count < minCustomDepthBelowHome {
                return "must be at least \(minCustomDepthBelowHome) levels below the home directory"
            }
            for d in denied where f == d || isInside(d, f) {
                return "is or contains a protected directory (\(d))"
            }
            for t in trees where isInside(f, t) {
                return "lies inside a protected directory (\(t))"
            }
        }
        return nil
    }
}
