import Foundation

/// Static table of the optional shared PHP extensions RAMP knows how to enable (no disk access).
///
/// Availability per branch = what the installed package ships (`InstalledPackage.extensions`, from the
/// manifest) ∩ this catalog. Compiled-in extensions the manifest may also list (mbstring, intl, opcache…)
/// are ignored. Unknown availability (`nil`, older records) = empty set; 04-03 adds an ext-dir scan fallback.
public enum PHPExtensionCatalog {
    public enum Kind: Sendable, Equatable {
        /// `extension=<name>`
        case `extension`
        /// `zend_extension=<name>`
        case zendExtension
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        /// conf.d file prefix (`NN-<name>.ini`), defines load order.
        public let prefix: Int
        /// Branches where the extension is on by default (when available); `nil` = every branch.
        /// Empty = never on by default (Xdebug: only via `PHPBranchSettings.xdebug`).
        public let defaultBranches: Set<String>?

        public func defaultEnabled(branch: String) -> Bool {
            defaultBranches.map { $0.contains(branch) } ?? true
        }

        public var fileName: String { "\(prefix)-\(name).ini" }
    }

    /// Load order: prefix, then name. MAMP parity: apcu/imagick/memcached/redis/yaml on wherever shipped;
    /// Phalcon on by default only on 8.2 (Tyrestock), loaded after the others.
    public static let entries: [Entry] = [
        Entry(name: "apcu", kind: .extension, prefix: 20, defaultBranches: nil),
        Entry(name: "imagick", kind: .extension, prefix: 20, defaultBranches: nil),
        Entry(name: "memcached", kind: .extension, prefix: 20, defaultBranches: nil),
        Entry(name: "redis", kind: .extension, prefix: 20, defaultBranches: nil),
        Entry(name: "yaml", kind: .extension, prefix: 20, defaultBranches: nil),
        Entry(name: "phalcon", kind: .extension, prefix: 30, defaultBranches: ["8.2"]),
        Entry(name: "xdebug", kind: .zendExtension, prefix: 90, defaultBranches: []),
    ]

    public static func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// Catalog extensions the installed package of `branch` ships.
    public static func available(branch: String, config: RampConfig) -> Set<String> {
        guard let shipped = config.installed["php"]?[branch]?.extensions else { return [] }
        return Set(shipped).intersection(entries.map(\.name))
    }
}
