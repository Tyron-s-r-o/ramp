import Foundation

/// One effective php.ini directive and the layer it comes from.
public struct IniDirective: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable, Codable, Hashable {
        /// RAMP defaults (`PHPIniDefaults`), identical for every branch.
        case base
        /// `PHPSettings.globalIniOverrides`.
        case global
        /// `PHPBranchSettings.iniOverrides` of the branch.
        case branch
    }

    public var key: String
    public var value: String
    public var source: Source

    public init(key: String, value: String, source: Source) {
        self.key = key
        self.value = value
        self.source = source
    }
}

/// Resolves php.ini layering: base defaults → global overrides → per-branch overrides (later wins).
/// Pure; used by `PHPIniGenerator` and the GUI ini editor ("where does memory_limit come from?").
public enum PHPIniLayers {
    static let keyPattern = #"^[A-Za-z_][A-Za-z0-9_.]*(\[[A-Za-z0-9_.-]+\])?\z"#
    static let rawValuePattern = #"^[A-Za-z0-9_.+\-/:,@%~&|^!() ]*\z"#
    /// Managed by RAMP (extension loading / typed settings in conf.d) — never user-overridable.
    static let protectedKeys: Set<String> = ["extension", "zend_extension", "extension_dir"]
    static let protectedPrefixes = ["opcache.", "xdebug.", "apc."]

    /// Effective directives for `branch`: base table order first, then override-only keys sorted by key.
    /// Throws `GeneratorError.invalidValue(key: "php.iniOverrides", value: <key>)` for a malformed or
    /// protected key, and `invalidValue(key: "php.iniOverrides[<key>]", …)` for a value containing CR/LF/NUL.
    public static func effective(config: RampConfig, branch: String, paths: Paths) throws -> [IniDirective] {
        var directives = (PHPIniDefaults.base + PHPIniDefaults.rampPaths(config: config, paths: paths))
            .map { IniDirective(key: $0.key, value: $0.value, source: .base) }
        let index = Dictionary(uniqueKeysWithValues: directives.enumerated().map { ($1.key, $0) })
        var extra: [String: IniDirective] = [:]

        func apply(_ overrides: [String: String], source: IniDirective.Source) throws {
            for key in overrides.keys.sorted() {
                let value = overrides[key]!
                try validate(key: key, value: value)
                let d = IniDirective(key: key, value: value, source: source)
                if let i = index[key] { directives[i] = d } else { extra[key] = d }
            }
        }
        try apply(config.php.globalIniOverrides, source: .global)
        try apply(config.php.branches[branch]?.iniOverrides ?? [:], source: .branch)

        return directives + extra.keys.sorted().map { extra[$0]! }
    }

    /// `true` for directives RAMP manages itself (`extension`, `zend_extension`, `extension_dir`,
    /// `opcache.*`, `xdebug.*`, `apc.*`); case-insensitive.
    public static func isProtected(_ key: String) -> Bool {
        let k = key.lowercased()
        return protectedKeys.contains(k) || protectedPrefixes.contains { k.hasPrefix($0) }
    }

    /// Validates one override (key syntax, protected keys, value control characters).
    public static func validate(key: String, value: String) throws {
        guard key.range(of: keyPattern, options: .regularExpression) != nil, !isProtected(key) else {
            throw GeneratorError.invalidValue(key: "php.iniOverrides", value: key)
        }
        do { try ConfigText.validate(value, key: key) } catch {
            throw GeneratorError.invalidValue(key: "php.iniOverrides[\(key)]", value: value)
        }
    }

    /// php.ini value encoding. Raw when it only contains safe characters (keeps constant expressions like
    /// `E_ALL & ~E_DEPRECATED` evaluated), has no leading/trailing space and is not a path; otherwise
    /// double-quoted with `\`, `"` and `$` escaped (no `${…}` expansion of user input).
    public static func encode(_ value: String) throws -> String {
        try ConfigText.validate(value, key: "php.ini value")
        let raw = value.range(of: rawValuePattern, options: .regularExpression) != nil
            && !value.hasPrefix(" ") && !value.hasSuffix(" ") && !value.hasPrefix("/")
        if raw { return value }
        var escaped = ""
        for ch in value {
            if ch == "\\" || ch == "\"" || ch == "$" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }
}
