import Foundation

/// How a manifest entry relates to what is installed (plan 07-01).
public enum UpdateKind: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// Same branch, higher version, applied without asking (PHP patches in an enabled branch).
    case automatic
    /// Same branch, higher version, one-click update.
    case offered
    /// A branch newer than every installed branch of the component — offered as a new install.
    case newBranch
    /// MySQL major change (e.g. 9.7 → 10.x): dump + datadir upgrade, never automatic.
    case migration

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .automatic: "automatic"
        case .offered: "offered"
        case .newBranch: "newBranch"
        case .migration: "migration"
        }
    }
}

public struct UpdateItem: Sendable, Equatable, Hashable {
    public let component: String
    /// Target branch (for a migration: the new branch).
    public let branch: String
    /// Installed version being replaced; `nil` for a new branch. Migration: version of the highest installed branch.
    public let from: String?
    /// Manifest version.
    public let to: String
    public let kind: UpdateKind
    /// A `mysqldump --all-databases` must complete before the update/migration.
    public let requiresDumpFirst: Bool

    public init(component: String, branch: String, from: String?, to: String, kind: UpdateKind,
                requiresDumpFirst: Bool) {
        self.component = component
        self.branch = branch
        self.from = from
        self.to = to
        self.kind = kind
        self.requiresDumpFirst = requiresDumpFirst
    }
}

public struct UpdatePlan: Sendable, Equatable {
    /// Ordered: automatic, offered, newBranch, migration; within a kind by component, then numeric branch.
    public let items: [UpdateItem]

    public init(items: [UpdateItem]) { self.items = items }

    public var automatic: [UpdateItem] { items.filter { $0.kind == .automatic } }
    public var isEmpty: Bool { items.isEmpty }
}

/// Pure update rules: manifest × `config.installed` × settings → `UpdatePlan`. No I/O.
///
/// - Same branch, strictly higher version → PHP (enabled branch, `autoApplyPHPPatches`) `.automatic`,
///   everything else `.offered`; MySQL patches carry `requiresDumpFirst = dumpBeforeMySQLPatch`.
/// - Uninstalled branch newer than every installed branch of an installed component → `.newBranch`
///   (older uninstalled branches belong to the install UI, not to updates). A component that is not
///   installed at all yields nothing (e.g. Elasticsearch never installed).
/// - MySQL: a newer branch is a `.migration` (always dump first); `migrationOnlyBranches` never appear.
public enum UpdatePolicy {
    /// Branches that exist in the manifest only as migration helpers (8.0 → 8.4 → 9.7 upgrade chain).
    public static let migrationOnlyBranches: [String: Set<String>] = ["mysql": ["8.4"]]

    public static func plan(manifest: Manifest, installed: [String: [String: InstalledPackage]],
                            settings: UpdateSettings,
                            phpBranches: [String: PHPBranchSettings] = [:]) -> UpdatePlan {
        var items: [UpdateItem] = []
        for (component, branches) in manifest.components where Manifest.knownComponents.contains(component) {
            let installedBranches = installed[component] ?? [:]
            let highestInstalled = installedBranches.keys.max(by: branchLess)
            for (branch, entry) in branches {
                if migrationOnlyBranches[component]?.contains(branch) == true { continue }
                guard let target = PackageVersion(entry.version) else { continue }

                if let current = installedBranches[branch] {
                    guard let have = PackageVersion(current.version), target > have else { continue }
                    let kind: UpdateKind
                    if component == "php", settings.autoApplyPHPPatches, phpBranches[branch]?.enabled ?? true {
                        kind = .automatic
                    } else {
                        kind = .offered
                    }
                    items.append(UpdateItem(component: component, branch: branch, from: current.version,
                                            to: entry.version, kind: kind,
                                            requiresDumpFirst: component == "mysql" && settings.dumpBeforeMySQLPatch))
                } else if let highest = highestInstalled, branchLess(highest, branch) {
                    if component == "mysql" {
                        items.append(UpdateItem(component: component, branch: branch,
                                                from: installedBranches[highest]?.version, to: entry.version,
                                                kind: .migration, requiresDumpFirst: true))
                    } else {
                        items.append(UpdateItem(component: component, branch: branch, from: nil,
                                                to: entry.version, kind: .newBranch, requiresDumpFirst: false))
                    }
                }
            }
        }
        items.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.component != $1.component { return $0.component < $1.component }
            return branchLess($0.branch, $1.branch)
        }
        return UpdatePlan(items: items)
    }

    /// Convenience: plan straight from `ramp.json`.
    public static func plan(manifest: Manifest, config: RampConfig) -> UpdatePlan {
        plan(manifest: manifest, installed: config.installed, settings: config.updates,
             phpBranches: config.php.branches)
    }

    /// Numeric branch order (`8.4` < `8.10` < `10.0`).
    public static func branchLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}

/// Which version directories of one branch may be deleted after a successful update.
public enum RetentionPolicy {
    /// Every `<component>/<version>` directory of `branch` except `current` and `previous`.
    /// Names that are not versions of this branch (`current`, `.staging`, the branch dir `8.3`,
    /// other branches' versions) are never returned. Sorted ascending, deduplicated.
    public static func prunable(component: String, branch: String, versionsOnDisk: [String],
                                current: String, previous: String?) -> [String] {
        let keep: Set<String> = [current, previous].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        let branchDepth = branch.split(separator: ".").count
        var seen = Set<String>()
        return versionsOnDisk
            .filter { name in
                guard !keep.contains(name), seen.insert(name).inserted,
                      name.hasPrefix(branch + "."),
                      let v = PackageVersion(name), v.components.count > branchDepth else { return false }
                return true
            }
            .sorted { PackageVersion($0)! < PackageVersion($1)! }
    }
}

extension InstalledPackage {
    /// Record after a successful update: new version/sha/date, the replaced version becomes `previous*`.
    /// Other fields (extension dir, opcache, extensions) are carried over; the caller refreshes them
    /// from the new package tree.
    public func recordingUpdate(to newVersion: String, sha256: String, at date: Date) -> InstalledPackage {
        var record = self
        record.previousVersion = version
        record.previousSHA256 = self.sha256
        record.version = newVersion
        record.sha256 = sha256
        record.installedAt = date
        return record
    }
}
