import Foundation

/// Project folder for a vhost docroot: PhpStorm / Finder should open the project, not its `www/` or
/// `public/` subfolder. Read-only metadata checks through `FileChecking`.
public enum ProjectRoot {
    /// Maximum number of parent directories inspected above the docroot.
    public static let maxLevelsUp = 3

    /// First directory (the docroot itself, then up to `maxLevelsUp` parents) that contains `.idea` or `.git`
    /// (directory, or file for git worktrees). Never returns `home` or anything above it; nothing found →
    /// the docroot itself.
    public static func resolve(docroot: String, home: URL, fs: any FileChecking) -> String {
        let start = normalize(docroot)
        let homePath = normalize(home.path(percentEncoded: false))
        guard start.hasPrefix("/") else { return docroot }
        var current = start
        for _ in 0...maxLevelsUp {
            guard current != "/", current != homePath, !isAbove(current, home: homePath) else { break }
            if isProject(current, fs: fs) { return current }
            current = parent(of: current)
        }
        return start
    }

    static func isProject(_ dir: String, fs: any FileChecking) -> Bool {
        fs.kind(at: dir + "/.idea") == .directory || fs.kind(at: dir + "/.git") != .missing
    }

    /// `path` is `home`'s ancestor (e.g. `/Users` for `/Users/tester`).
    static func isAbove(_ path: String, home: String) -> Bool {
        path == "/" || home.hasPrefix(path + "/")
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let head = String(path[..<slash])
        return head.isEmpty ? "/" : head
    }
}
