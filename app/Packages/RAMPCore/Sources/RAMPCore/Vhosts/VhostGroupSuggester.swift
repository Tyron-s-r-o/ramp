import Foundation

/// Proposes a vhost group from the docroot's folder layout under the user's Sites folder.
///
/// The first folder below `sitesRoot` is taken as the group when the docroot lies at least two levels below it
/// (`~/Sites/ASTEEL/tyrefleet.eu/public` → "ASTEEL"); a project directly in Sites (`~/Sites/chargeo/public`) or a
/// docroot outside Sites gets no suggestion. Pure string logic — no filesystem access.
public enum VhostGroupSuggester {
    /// `~/Sites` of `home`.
    public static func sitesRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appending(path: "Sites", directoryHint: .isDirectory).path(percentEncoded: false)
    }

    public static func suggest(docroot: String, sitesRoot: String) -> String? {
        let root = components(sitesRoot)
        let path = components(docroot)
        guard !root.isEmpty, path.count >= root.count + 3 else { return nil }
        // APFS is case-insensitive by default: ~/sites/… is the same folder as ~/Sites/….
        for (a, b) in zip(root, path) where a.caseInsensitiveCompare(b) != .orderedSame { return nil }
        let candidate = path[root.count].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = Vhost.normalizeGroup(String(candidate.prefix(Vhost.maxGroupLength))),
              VhostValidator.groupProblem(group) == nil
        else { return nil }
        return group
    }

    /// Absolute path → components without empty / "." parts, ".." resolved lexically; relative → [].
    private static func components(_ path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(String(part))
            }
        }
        return result
    }
}
