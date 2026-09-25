import Foundation

/// `ramp.json` → `elasticsearch` (plan 06-01). Missing key / missing fields = defaults.
///
/// Elasticsearch is an optional service: it never autostarts and is not part of
/// `ServiceSpecFactory.specs` (see `ServiceSpecFactory.elasticsearch`).
public struct ElasticsearchSettings: Codable, Sendable, Equatable {
    /// Installed branch to run (`installed["elasticsearch"][branch]`).
    public var branch: String
    public var httpPort: Int
    public var transportPort: Int
    /// Loopback only (`127.0.0.1`, `::1`, `localhost`) — security is disabled.
    public var bindAddress: String
    /// JVM heap, used for both `-Xms` and `-Xmx` (e.g. `1g`, `512m`; 256m…31g).
    public var heap: String
    /// Desired plugin set (reconciled with `elasticsearch-plugin`, plan 06-03).
    public var plugins: [String]
    public var autoStop: AutoStopSettings

    public init(branch: String = "9.5", httpPort: Int = 9200, transportPort: Int = 9300,
                bindAddress: String = "127.0.0.1", heap: String = "1g", plugins: [String] = [],
                autoStop: AutoStopSettings = AutoStopSettings()) {
        self.branch = branch
        self.httpPort = httpPort
        self.transportPort = transportPort
        self.bindAddress = bindAddress
        self.heap = heap
        self.plugins = plugins
        self.autoStop = autoStop
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? d.branch
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort) ?? d.httpPort
        transportPort = try c.decodeIfPresent(Int.self, forKey: .transportPort) ?? d.transportPort
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        heap = try c.decodeIfPresent(String.self, forKey: .heap) ?? d.heap
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? d.plugins
        autoStop = try c.decodeIfPresent(AutoStopSettings.self, forKey: .autoStop) ?? d.autoStop
    }
}

/// When a running Elasticsearch is stopped automatically. Plain data; parsing, validation and
/// scheduling live in `AutoStopPolicy` (plan 06-02).
///
/// A missing key means the default; an explicit JSON `null` means "off" (so `afterHours: null`
/// survives a round trip instead of falling back to 6).
public struct AutoStopSettings: Codable, Sendable, Equatable {
    /// Stop after this many hours of running. `nil` = off.
    public var afterHours: Int?
    /// Stop at this local wall-clock time, `"HH:mm"`. `nil` = off (UI suggests `"01:00"`).
    public var atTime: String?

    private enum CodingKeys: String, CodingKey { case afterHours, atTime }

    public init(afterHours: Int? = 6, atTime: String? = nil) {
        self.afterHours = afterHours
        self.atTime = atTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        afterHours = c.contains(.afterHours) ? try c.decodeIfPresent(Int.self, forKey: .afterHours) : d.afterHours
        atTime = c.contains(.atTime) ? try c.decodeIfPresent(String.self, forKey: .atTime) : d.atTime
    }

    /// Allowed `afterHours` (plan 06-02).
    public static let afterHoursRange = 1...72

    /// Parsed `atTime`; `nil` when off or malformed.
    public var time: AutoStopTime? { atTime.flatMap(AutoStopTime.init) }

    /// Throws `AutoStopError` for `afterHours` outside 1…72 or an `atTime` that is not `H:mm`/`HH:mm`.
    public func validate() throws {
        if let h = afterHours, !Self.afterHoursRange.contains(h) { throw AutoStopError.invalidAfterHours(h) }
        if let t = atTime, AutoStopTime(t) == nil { throw AutoStopError.invalidTime(t) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Explicit null keeps "off" distinguishable from "missing = default".
        try c.encode(afterHours, forKey: .afterHours)
        try c.encode(atTime, forKey: .atTime)
    }
}
