import Foundation

/// Per-branch Xdebug mode (`ramp.json` strings `off | debug | profile`). Always trigger-only
/// (`XDEBUG_TRIGGER` cookie/GET/POST), IDE port 9003. `.off` = the extension is not loaded at all.
public enum XdebugMode: String, Codable, Sendable, CaseIterable {
    case off, debug, profile
}

/// Per-branch OPcache settings → `conf.d/10-opcache.ini`.
public struct OPcacheOptions: Codable, Sendable, Equatable {
    public enum Profile: String, Codable, Sendable, CaseIterable {
        /// `validate_timestamps=1`, `revalidate_freq=0` — edits visible immediately.
        case development
        /// `validate_timestamps=0` + JIT (PHP ≥ 8) — code changes need an FPM reload / `opcache_reset()`.
        case performance
    }

    /// `false` → `opcache.enable=0`; the extension stays loaded so `opcache_*()` calls never fatal.
    public var enabled: Bool
    public var profile: Profile
    /// Tracing JIT with a 128M buffer (PHP ≥ 8 only; ignored on 7.x). Implied by `.performance`.
    public var jit: Bool

    public init(enabled: Bool = true, profile: Profile = .development, jit: Bool = false) {
        self.enabled = enabled
        self.profile = profile
        self.jit = jit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        profile = try c.decodeIfPresent(String.self, forKey: .profile).flatMap(Profile.init(rawValue:)) ?? d.profile
        jit = try c.decodeIfPresent(Bool.self, forKey: .jit) ?? d.jit
    }
}

/// Per-branch APCu settings → `conf.d/20-apcu.ini` (only when apcu is effective-enabled).
public struct APCuOptions: Codable, Sendable, Equatable {
    /// `apc.shm_size`, validated like other sizes (`128M`, `1G`).
    public var shmSize: String

    public init(shmSize: String = "128M") { self.shmSize = shmSize }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shmSize = try c.decodeIfPresent(String.self, forKey: .shmSize) ?? Self().shmSize
    }
}

/// Menu-bar indicator support.
public enum XdebugStatus {
    /// Installed + enabled PHP branches with Xdebug mode ≠ off, numerically sorted.
    public static func enabledBranches(_ config: RampConfig) -> [String] {
        GeneratorSupport.enabledPHPBranches(config).filter { (config.php.branches[$0]?.xdebug ?? .off) != .off }
    }
}
