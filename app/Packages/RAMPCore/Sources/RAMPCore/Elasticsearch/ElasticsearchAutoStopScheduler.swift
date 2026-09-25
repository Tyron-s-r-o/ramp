import Foundation

/// What the auto-stop scheduler needs from Elasticsearch (implemented by `ElasticsearchService`, faked in tests).
public protocol ElasticsearchControlling: Sendable {
    func state() async -> ServiceState
    func stop() async
}

extension ElasticsearchService: ElasticsearchControlling {}

/// Auto-stop state for the UI / `rampctl es status` (plan 06-04).
public struct AutoStopStatus: Sendable, Equatable {
    /// Start of the current ES session (kept across crash restarts); nil = no session (ES stopped).
    public var sessionStart: Date?
    /// Effective deadline; nil with a session = auto-stop disabled.
    public var deadline: Date?
    public var reason: AutoStopReason?
    /// `deadline - now` (≥ 0).
    public var remaining: Duration?

    public init(sessionStart: Date? = nil, deadline: Date? = nil, reason: AutoStopReason? = nil,
                remaining: Duration? = nil) {
        self.sessionStart = sessionStart
        self.deadline = deadline
        self.reason = reason
        self.remaining = remaining
    }

    public static let inactive = AutoStopStatus()

    /// ES session running.
    public var isActive: Bool { sessionStart != nil }
    /// Session running but no auto-stop configured.
    public var isDisabled: Bool { sessionStart != nil && deadline == nil }

    /// Slovak one-liner for rampctl: `"auto-stop: o 01:00 (po 6 h) — zostáva 4 h 12 min"` / `"auto-stop: vypnutý"`.
    public func cliDescription(calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let deadline, let reason else { return "auto-stop: vypnutý" }
        var text = "auto-stop: o \(Self.clock(deadline, calendar: calendar)) (\(Self.reasonText(reason)))"
        if let remaining { text += " — zostáva \(Self.remainingText(remaining))" }
        return text
    }

    /// `"po 6 h"` / `"v čase 01:00"` / `"predĺžené"`.
    public static func reasonText(_ reason: AutoStopReason) -> String {
        switch reason {
        case .afterHours(let h): return h == 0 ? "po \(ElasticsearchAutoStopScheduler.overrideEnvironmentKey)" : "po \(h) h"
        case .atTime(let t): return "v čase \(t)"
        case .postponed: return "predĺžené"
        }
    }

    /// `"4 h 12 min"`, `"12 min"`, `"0 min"` (seconds rounded up to the next minute).
    public static func remainingText(_ remaining: Duration) -> String {
        let seconds = max(0, remaining.components.seconds)
        let minutes = Int((seconds + 59) / 60)
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h) h \(m < 10 ? "0" : "")\(m) min" : "\(m) min"
    }

    /// Local `HH:mm`.
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return AutoStopTime(hour: c.hour ?? 0, minute: c.minute ?? 0)?.description ?? "--:--"
    }
}

/// In-process auto-stop for Elasticsearch (plan 06-04) — replaces the external `com.rv.elastic-autostop`
/// LaunchAgent. Used by the app and by `rampctl up`.
///
/// - Session: starts when ES is started by a request (`sessionStarted(at:)`) or when a tick first sees it
///   starting/running/backing off; survives crash restarts (`backingOff`/`starting` in between); ends when ES is
///   seen stopped/failed, on `sessionEnded()` and after an auto-stop. The postponement belongs to the session.
/// - `tick(now:)` holds the whole logic: `AutoStopPolicy.decide` → `.stopNow` → marker in `<logs>/elasticsearch.log`
///   + `es.stop()`, exactly once per session. Settings are re-read on every tick.
/// - `run()` ticks every 30 s; `wake()` ticks immediately (app: `NSWorkspace.didWakeNotification`). Wall-clock
///   `Date()` is used, so time spent asleep counts (deadline passed while asleep → stop on the first tick).
/// - `overrideAfterSeconds` (rampctl only, env `RAMP_ES_AUTOSTOP_SECONDS`, test aid): deadline = start + N s
///   instead of the configured rules.
public actor ElasticsearchAutoStopScheduler {
    public typealias SettingsProvider = @Sendable () async -> AutoStopSettings

    /// Env var honoured by `rampctl up` / `rampctl es status` only (the app ignores it).
    public static let overrideEnvironmentKey = "RAMP_ES_AUTOSTOP_SECONDS"
    public static let tickInterval: Duration = .seconds(30)

    private let es: any ElasticsearchControlling
    private let settings: SettingsProvider
    private let calendar: @Sendable () -> Calendar
    private let log: LogSink
    private let stateFile: URL?
    private let overrideAfterSeconds: TimeInterval?

    public private(set) var sessionStart: Date?
    public private(set) var postponedUntil: Date?
    /// Set by an auto-stop until ES is seen stopped (no re-adoption of a stopping ES as a new session).
    private var autoStopped = false

    public nonisolated let updates: AsyncStream<AutoStopStatus>
    private let continuation: AsyncStream<AutoStopStatus>.Continuation

    /// `stateFile` (e.g. `run/es-autostop.json`) persists session start + postponement for other processes
    /// (`rampctl es status`).
    public init(es: any ElasticsearchControlling, settings: @escaping SettingsProvider,
                calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent }, log: LogSink,
                stateFile: URL? = nil, overrideAfterSeconds: TimeInterval? = nil) {
        self.es = es
        self.settings = settings
        self.calendar = calendar
        self.log = log
        self.stateFile = stateFile
        self.overrideAfterSeconds = overrideAfterSeconds
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// `run/es-autostop.json`.
    public static func stateFile(paths: Paths) -> URL {
        paths.runDir.appending(path: "es-autostop.json", directoryHint: .notDirectory)
    }

    /// Positive seconds from `RAMP_ES_AUTOSTOP_SECONDS`, else nil.
    public static func overrideFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> TimeInterval? {
        guard let raw = env[overrideEnvironmentKey], let value = TimeInterval(raw), value > 0 else { return nil }
        return value
    }

    // MARK: Loop

    /// Ticks every `interval` until the task is cancelled.
    public func run(interval: Duration = ElasticsearchAutoStopScheduler.tickInterval) async {
        while !Task.isCancelled {
            await tick(now: Date())
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// After system wake: tick right away (a deadline passed during sleep stops ES now).
    public func wake() async {
        await tick(now: Date())
    }

    // MARK: Session

    /// ES was started on request. Starts a session unless one is already running (restart keeps the deadline).
    public func sessionStarted(at now: Date) async {
        autoStopped = false
        if sessionStart == nil {
            sessionStart = now
            postponedUntil = nil
            persist()
        }
        continuation.yield(await status(now: now))
    }

    /// ES was stopped on request.
    public func sessionEnded(now: Date = Date()) async {
        autoStopped = false
        clearSession()
        continuation.yield(await status(now: now))
    }

    /// Postpones the stop by `by` (`max(now, deadline) + by`). No session / auto-stop disabled → unchanged.
    @discardableResult
    public func postpone(now: Date, by: Duration = .seconds(3600)) async -> AutoStopStatus {
        let current = await settings()
        guard let start = sessionStart,
              let (deadline, _) = Self.deadline(startedAt: start, settings: current, postponedUntil: postponedUntil,
                                                calendar: calendar(), overrideAfterSeconds: overrideAfterSeconds)
        else { return await status(now: now) }
        postponedUntil = AutoStopPolicy.postpone(now: now, currentDeadline: deadline, by: by)
        persist()
        let result = await status(now: now)
        continuation.yield(result)
        return result
    }

    // MARK: Tick

    /// The whole auto-stop logic for one point in time (tests call it with explicit `now`s).
    public func tick(now: Date) async {
        let state = await es.state()
        switch state {
        case .stopped, .failed:
            autoStopped = false
            if sessionStart != nil { clearSession() }
        case .starting, .running, .backingOff:
            if sessionStart == nil && !autoStopped {
                sessionStart = now
                postponedUntil = nil
                persist()
            }
        case .stopping:
            break
        }
        let current = await settings()
        if let start = sessionStart, state != .stopping {
            let decision = Self.decide(now: now, startedAt: start, settings: current, postponedUntil: postponedUntil,
                                       calendar: calendar(), overrideAfterSeconds: overrideAfterSeconds)
            if case .stopNow(let reason) = decision {
                // Cleared before awaiting the stop: a re-entrant tick (wake) must not stop twice.
                clearSession()
                autoStopped = true
                writeMarker(markerText(reason), date: now)
                continuation.yield(.inactive)
                await es.stop()
            }
        }
        continuation.yield(Self.status(now: now, sessionStart: sessionStart, postponedUntil: postponedUntil,
                                       settings: current, calendar: calendar(),
                                       overrideAfterSeconds: overrideAfterSeconds))
    }

    public func status(now: Date) async -> AutoStopStatus {
        Self.status(now: now, sessionStart: sessionStart, postponedUntil: postponedUntil, settings: await settings(),
                    calendar: calendar(), overrideAfterSeconds: overrideAfterSeconds)
    }

    /// Marker line text (`"auto-stop: po 6 h"`, `"auto-stop: o 01:00"`, `"auto-stop: po predĺžení"`).
    func markerText(_ reason: AutoStopReason) -> String {
        switch reason {
        case .afterHours(let h):
            if let o = overrideAfterSeconds { return "auto-stop: po \(Int(o)) s (\(Self.overrideEnvironmentKey))" }
            return "auto-stop: po \(h) h"
        case .atTime(let t): return "auto-stop: o \(t)"
        case .postponed: return "auto-stop: po predĺžení"
        }
    }

    // MARK: Pure helpers (shared with rampctl es status)

    public static func deadline(startedAt: Date, settings: AutoStopSettings, postponedUntil: Date?,
                                calendar: Calendar, overrideAfterSeconds: TimeInterval?) -> (Date, AutoStopReason)? {
        guard let override = overrideAfterSeconds else {
            return AutoStopPolicy.deadline(startedAt: startedAt, settings: settings, postponedUntil: postponedUntil,
                                           calendar: calendar)
        }
        let base = startedAt.addingTimeInterval(override)
        if let postponedUntil, postponedUntil > base { return (postponedUntil, .postponed) }
        return (base, .afterHours(0))
    }

    public static func decide(now: Date, startedAt: Date, settings: AutoStopSettings, postponedUntil: Date?,
                              calendar: Calendar, overrideAfterSeconds: TimeInterval?) -> AutoStopDecision {
        guard let (deadline, reason) = deadline(startedAt: startedAt, settings: settings, postponedUntil: postponedUntil,
                                                calendar: calendar, overrideAfterSeconds: overrideAfterSeconds)
        else { return .disabled }
        return now >= deadline ? .stopNow(reason) : .keepRunning(deadline: deadline, reason: reason)
    }

    public static func status(now: Date, sessionStart: Date?, postponedUntil: Date?, settings: AutoStopSettings,
                              calendar: Calendar, overrideAfterSeconds: TimeInterval? = nil) -> AutoStopStatus {
        guard let start = sessionStart else { return .inactive }
        guard let (deadline, reason) = deadline(startedAt: start, settings: settings, postponedUntil: postponedUntil,
                                                calendar: calendar, overrideAfterSeconds: overrideAfterSeconds)
        else { return AutoStopStatus(sessionStart: start) }
        let remaining = max(0, deadline.timeIntervalSince(now))
        return AutoStopStatus(sessionStart: start, deadline: deadline, reason: reason,
                              remaining: .seconds(Int64(remaining.rounded(.down))))
    }

    // MARK: Persistence

    public struct Persisted: Codable, Sendable, Equatable {
        public var sessionStart: Date
        public var postponedUntil: Date?
    }

    /// Persisted session of another process (`rampctl up`); nil when missing.
    public static func loadPersisted(from url: URL) -> Persisted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Persisted.self, from: data)
    }

    // MARK: Private

    private func clearSession() {
        sessionStart = nil
        postponedUntil = nil
        persist()
    }

    private func persist() {
        guard let stateFile else { return }
        guard let start = sessionStart else {
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Persisted(sessionStart: start, postponedUntil: postponedUntil)) else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    private func writeMarker(_ text: String, date: Date) {
        guard let handle = try? log.open(service: ServiceID.elasticsearch.name) else { return }
        LogSink.marker(handle, text, date: date)
        try? handle.close()
    }
}
