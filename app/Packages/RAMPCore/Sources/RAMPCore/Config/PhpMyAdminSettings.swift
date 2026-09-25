import Foundation

/// `ramp.json` → `phpmyadmin` (plan 04-04). Missing key / missing fields = defaults.
///
/// phpMyAdmin is served at `http://localhost/phpmyadmin` (localhost site only) with auto-login as MySQL root.
public struct PhpMyAdminSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// PHP branch that runs phpMyAdmin. `nil` = highest installed + enabled branch.
    public var phpBranch: String?
    /// Cookie encryption secret (exactly 32 chars `[A-Za-z0-9]`). Generated once by `StackController`
    /// (never by the generator) and never regenerated — a new secret would only log everyone out.
    public var blowfishSecret: String?

    public init(enabled: Bool = true, phpBranch: String? = nil, blowfishSecret: String? = nil) {
        self.enabled = enabled
        self.phpBranch = phpBranch
        self.blowfishSecret = blowfishSecret
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        phpBranch = try c.decodeIfPresent(String.self, forKey: .phpBranch)
        blowfishSecret = try c.decodeIfPresent(String.self, forKey: .blowfishSecret)
    }
}
