import Foundation

/// `ramp.json` → `updates` (plan 07-01). Missing key / missing fields = defaults; schema stays 1.
public struct UpdateSettings: Codable, Sendable, Equatable {
    public static let intervalRange = 1...168

    /// How often the manifest is checked (hours, clamped to 1…168).
    public var checkIntervalHours: Int {
        didSet { checkIntervalHours = Self.clamp(checkIntervalHours) }
    }
    /// PHP patch updates within an installed, enabled branch are applied without asking.
    public var autoApplyPHPPatches: Bool
    /// `mysqldump --all-databases` before a MySQL patch update (a major change always dumps).
    public var dumpBeforeMySQLPatch: Bool

    public init(checkIntervalHours: Int = 24, autoApplyPHPPatches: Bool = true, dumpBeforeMySQLPatch: Bool = true) {
        self.checkIntervalHours = Self.clamp(checkIntervalHours)
        self.autoApplyPHPPatches = autoApplyPHPPatches
        self.dumpBeforeMySQLPatch = dumpBeforeMySQLPatch
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            checkIntervalHours: try c.decodeIfPresent(Int.self, forKey: .checkIntervalHours) ?? d.checkIntervalHours,
            autoApplyPHPPatches: try c.decodeIfPresent(Bool.self, forKey: .autoApplyPHPPatches) ?? d.autoApplyPHPPatches,
            dumpBeforeMySQLPatch: try c.decodeIfPresent(Bool.self, forKey: .dumpBeforeMySQLPatch) ?? d.dumpBeforeMySQLPatch)
    }

    private static func clamp(_ hours: Int) -> Int {
        min(max(hours, intervalRange.lowerBound), intervalRange.upperBound)
    }
}
