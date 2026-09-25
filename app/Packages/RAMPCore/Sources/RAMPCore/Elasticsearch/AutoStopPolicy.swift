import Foundation

/// Local wall-clock time of day for `AutoStopSettings.atTime` (plan 06-02).
public struct AutoStopTime: Sendable, Hashable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses `"H:mm"` / `"HH:mm"` (ASCII digits only, no whitespace; minutes always two digits).
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// `"HH:mm"`.
    public var description: String {
        (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
    }
}

public enum AutoStopError: Error, Equatable, CustomStringConvertible {
    /// `afterHours` outside `AutoStopSettings.afterHoursRange`.
    case invalidAfterHours(Int)
    /// `atTime` is not `"H:mm"` / `"HH:mm"`.
    case invalidTime(String)

    public var description: String {
        switch self {
        case .invalidAfterHours(let h):
            return "Auto-stop after \(h) h is not allowed (\(AutoStopSettings.afterHoursRange.lowerBound)"
                + "–\(AutoStopSettings.afterHoursRange.upperBound) h)"
        case .invalidTime(let t): return "Auto-stop time \(t.debugDescription) is not a valid HH:mm time"
        }
    }
}

/// Why Elasticsearch is (going to be) stopped.
public enum AutoStopReason: Sendable, Equatable {
    case afterHours(Int)
    case atTime(AutoStopTime)
    /// The user postponed the stop; the postponement is the effective deadline.
    case postponed
}

public enum AutoStopDecision: Sendable, Equatable {
    /// No auto-stop configured.
    case disabled
    case keepRunning(deadline: Date, reason: AutoStopReason)
    case stopNow(AutoStopReason)
}

/// Pure auto-stop rules (plan 06-02). No clock, no `Calendar.current`, no stored state — the session
/// start, postponement and timer live in the app's scheduler (06-04).
///
/// | Setting | Deadline |
/// |---|---|
/// | `afterHours = h` | `startedAt + h·3600 s` (elapsed time; DST does not change it) |
/// | `atTime = HH:mm` | first local `HH:mm:00` strictly after `startedAt + grace` (15 min); spring-forward gap → next existing time; fall-back → first occurrence |
/// | both | the earlier one (with its reason) |
/// | `postponedUntil` later than the deadline | `postponedUntil` (`.postponed`); earlier / nil → ignored |
///
/// Invalid values (out-of-range hours, unparsable time) are ignored here — callers run
/// `AutoStopSettings.validate()` before starting Elasticsearch.
public enum AutoStopPolicy {
    /// Starting ES shortly before the configured time must not kill it minutes later.
    public static let grace: TimeInterval = 15 * 60

    public static func deadline(startedAt: Date, settings: AutoStopSettings, postponedUntil: Date?,
                                calendar: Calendar) -> (Date, AutoStopReason)? {
        var candidates: [(Date, AutoStopReason)] = []
        if let h = settings.afterHours, AutoStopSettings.afterHoursRange.contains(h) {
            candidates.append((startedAt.addingTimeInterval(TimeInterval(h) * 3600), .afterHours(h)))
        }
        if let raw = settings.atTime, let time = AutoStopTime(raw),
           let date = nextOccurrence(of: time, after: startedAt.addingTimeInterval(grace), calendar: calendar) {
            candidates.append((date, .atTime(time)))
        }
        // Stable: on a tie the after-hours entry (appended first) wins.
        guard let earliest = candidates.min(by: { $0.0 < $1.0 }) else { return nil }
        if let postponedUntil, postponedUntil > earliest.0 {
            return (postponedUntil, .postponed)
        }
        return earliest
    }

    public static func decide(now: Date, startedAt: Date, settings: AutoStopSettings, postponedUntil: Date?,
                              calendar: Calendar) -> AutoStopDecision {
        guard let (deadline, reason) = deadline(startedAt: startedAt, settings: settings,
                                                postponedUntil: postponedUntil, calendar: calendar) else {
            return .disabled
        }
        // `>=` also covers a Mac that slept through the deadline: the first tick after wake stops ES.
        return now >= deadline ? .stopNow(reason) : .keepRunning(deadline: deadline, reason: reason)
    }

    /// New postponement: `max(now, currentDeadline) + by`.
    public static func postpone(now: Date, currentDeadline: Date, by: Duration = .seconds(3600)) -> Date {
        let (seconds, attoseconds) = by.components
        return max(now, currentDeadline).addingTimeInterval(TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
    }

    /// First local `time` (seconds = 0) strictly after `date`.
    static func nextOccurrence(of time: AutoStopTime, after date: Date, calendar: Calendar) -> Date? {
        let match = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        guard let next = calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime,
                                           repeatedTimePolicy: .first, direction: .forward) else { return nil }
        if next > date { return next }
        return calendar.nextDate(after: date.addingTimeInterval(1), matching: match, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}
