import Foundation

/// Exponential-backoff restart policy for crashed services (pure value type).
///
/// `delay(attempt:)` = `min(base · 2^(attempt-1), max)` → 1, 2, 4, …, 32, 60, 60 s with the defaults.
/// A run that lasted at least `stableAfter` resets the attempt counter. `maxCrashes` crashes within
/// `window` → give up (service goes to `.failed`).
public struct BackoffPolicy: Sendable, Equatable {
    public var base: Duration
    public var max: Duration
    public var stableAfter: Duration
    public var maxCrashes: Int
    public var window: Duration

    public init(base: Duration = .seconds(1), max: Duration = .seconds(60), stableAfter: Duration = .seconds(60),
                maxCrashes: Int = 10, window: Duration = .seconds(600)) {
        self.base = base
        self.max = max
        self.stableAfter = stableAfter
        self.maxCrashes = maxCrashes
        self.window = window
    }

    public static let standard = BackoffPolicy()

    /// Delay before restart attempt `attempt` (1-based).
    public func delay(attempt: Int) -> Duration {
        let n = Swift.max(attempt, 1)
        // Avoid overflow: once 2^(n-1)·base exceeds max we are capped anyway.
        var d = base
        for _ in 1..<n {
            d = d * 2
            if d >= max { return max }
        }
        return Swift.min(d, max)
    }
}

/// Mutable crash bookkeeping for one service, driven by explicit instants (testable without a clock).
public struct BackoffTracker: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Restart after `delay`; `attempt` is 1-based.
        case restart(after: Duration, attempt: Int)
        /// Too many crashes within the window.
        case giveUp(crashes: Int)
    }

    public let policy: BackoffPolicy
    public private(set) var attempt = 0
    public private(set) var crashes: [ContinuousClock.Instant] = []

    public init(policy: BackoffPolicy) { self.policy = policy }

    /// Records an unexpected exit of a run that started at `startedAt` and ended at `exitedAt`.
    public mutating func recordCrash(startedAt: ContinuousClock.Instant,
                                     exitedAt: ContinuousClock.Instant) -> Decision {
        if startedAt.duration(to: exitedAt) >= policy.stableAfter { attempt = 0 }
        crashes.append(exitedAt)
        crashes.removeAll { $0.duration(to: exitedAt) > policy.window }
        if crashes.count >= policy.maxCrashes { return .giveUp(crashes: crashes.count) }
        attempt += 1
        return .restart(after: policy.delay(attempt: attempt), attempt: attempt)
    }

    /// Manual restart / start by the user clears the history.
    public mutating func reset() {
        attempt = 0
        crashes = []
    }
}
