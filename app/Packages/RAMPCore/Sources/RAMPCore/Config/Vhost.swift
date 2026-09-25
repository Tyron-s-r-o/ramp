import Foundation

/// One virtual host stored in `ramp.json` (`vhosts[]`). Apache config and the hosts block are derived from it.
///
/// Decoding is tolerant: missing keys fall back to defaults, unknown keys are ignored.
public struct Vhost: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Primary hostname, e.g. `asteel.local` (stored normalized: lowercased).
    public var domain: String
    /// Additional hostnames served by the same vhost (`ServerAlias`).
    public var aliases: [String]
    /// Absolute path of the project's document root. RAMP never writes into it.
    public var docroot: String
    /// PHP branch ("8.2"); `nil` = the Apache default branch.
    public var phpBranch: String?
    public var enabled: Bool
    /// UI folder the vhost is listed under ("ASTEEL"); `nil` = ungrouped. Stored trimmed, ≤ `maxGroupLength`
    /// characters. Purely organizational — never affects Apache or hosts output. Optional key (schema stays v1).
    public var group: String?

    public static let maxGroupLength = 40

    public init(id: UUID = UUID(), domain: String, aliases: [String] = [], docroot: String,
                phpBranch: String? = nil, enabled: Bool = true, group: String? = nil) {
        self.id = id
        self.domain = domain
        self.aliases = aliases
        self.docroot = docroot
        self.phpBranch = phpBranch
        self.enabled = enabled
        self.group = group
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        docroot = try c.decodeIfPresent(String.self, forKey: .docroot) ?? ""
        phpBranch = try c.decodeIfPresent(String.self, forKey: .phpBranch)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        group = try c.decodeIfPresent(String.self, forKey: .group)
    }

    /// Trimmed group name; empty / whitespace-only → `nil` (ungrouped).
    public static func normalizeGroup(_ input: String?) -> String? {
        guard let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Domain followed by aliases (as stored).
    public var hostnames: [String] { [domain] + aliases }

    /// Trims, lowercases and appends `.<tld>` when the input has no dot (`asteel` → `asteel.local`).
    public static func normalizeDomain(_ input: String, tld: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(".") else { return trimmed }
        let cleanTLD = tld.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n")).lowercased()
        return cleanTLD.isEmpty ? trimmed : "\(trimmed).\(cleanTLD)"
    }
}

/// `ramp.json` → `hosts`: how RAMP manages name resolution for vhosts.
public struct HostsSettings: Codable, Sendable, Equatable {
    /// Appended to dot-less domains entered in the UI.
    public var defaultTLD: String
    /// `true` = RAMP keeps its `# RAMP BEGIN/END` block in /etc/hosts in sync.
    public var manageHostsFile: Bool

    public init(defaultTLD: String = "local", manageHostsFile: Bool = true) {
        self.defaultTLD = defaultTLD
        self.manageHostsFile = manageHostsFile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        defaultTLD = try c.decodeIfPresent(String.self, forKey: .defaultTLD) ?? d.defaultTLD
        manageHostsFile = try c.decodeIfPresent(Bool.self, forKey: .manageHostsFile) ?? d.manageHostsFile
    }
}
