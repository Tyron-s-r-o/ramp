import Foundation

/// `ramp.json` → `cli`: terminal integration (`~/.ramp/bin` shims). Missing key / fields = defaults.
public struct CLISettings: Codable, Sendable, Equatable {
    /// PHP branch behind the unversioned `php` / `phpize` / `php-config` / `composer` shims.
    /// `nil` = `apache.defaultPHP`, else the highest installed + enabled branch (`CLIShimGenerator.defaultBranch`).
    public var defaultPHP: String?

    public init(defaultPHP: String? = nil) {
        self.defaultPHP = defaultPHP
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultPHP = try c.decodeIfPresent(String.self, forKey: .defaultPHP)
    }
}
