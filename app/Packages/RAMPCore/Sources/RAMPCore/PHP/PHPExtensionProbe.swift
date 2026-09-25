import Foundation

/// Runtime fallback for `InstalledPackage.extensions == nil` (older install records / manifests without an
/// `extensions` list): looks at the package's extension dir on disk.
public enum PHPExtensionProbe {
    /// Catalog extensions present as `<php current>/<extensionDirRel>/<name>.so`.
    /// `nil` when the branch has no install record, no `extensionDirRel`, or the directory is unreadable.
    public static func scan(branch: String, config: RampConfig, paths: Paths) -> Set<String>? {
        guard let pkg = config.installed["php"]?[branch], let rel = pkg.extensionDirRel, !rel.isEmpty else { return nil }
        let dir = paths.current(component: "php", branch: branch).appending(path: rel, directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else {
            return nil
        }
        let shipped = names.filter { $0.hasSuffix(".so") }.map { String($0.dropLast(3)) }
        return Set(shipped).intersection(PHPExtensionCatalog.entries.map(\.name))
    }

    /// Fills `installed["php"][b].extensions` (sorted) for every branch whose list is unknown and whose
    /// extension dir could be scanned. Returns the updated branches (empty = config unchanged).
    @discardableResult
    public static func fillMissing(config: inout RampConfig, paths: Paths) -> [String] {
        var updated: [String] = []
        for (branch, pkg) in config.installed["php"] ?? [:] where pkg.extensions == nil {
            guard let found = scan(branch: branch, config: config, paths: paths) else { continue }
            config.installed["php"]?[branch]?.extensions = found.sorted()
            updated.append(branch)
        }
        return updated.sorted()
    }
}
