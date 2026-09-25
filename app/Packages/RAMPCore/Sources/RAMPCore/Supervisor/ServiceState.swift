import Foundation

/// Lifecycle state of a supervised service.
///
/// stopped → starting → running(pid, since) → stopping → stopped;
/// unexpected exit → backingOff(attempt, until) → starting; too many crashes / bad config → failed(reason).
public enum ServiceState: Sendable, Equatable {
    case stopped
    case starting
    case running(pid: pid_t, since: Date)
    case stopping
    case backingOff(attempt: Int, until: Date)
    case failed(reason: String)

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
    public var pid: pid_t? { if case .running(let pid, _) = self { return pid } else { return nil } }
}

/// Events for observers (UI in Phase 5).
public enum ServiceEvent: Sendable, Equatable {
    case stateChanged(ServiceID, ServiceState)
    /// Process exited; `signal` is set when it was killed by a signal, otherwise `status` is the exit code.
    case exited(ServiceID, pid: pid_t, status: Int32, signal: Bool, requested: Bool)
    case restartScheduled(ServiceID, attempt: Int, delay: Duration)
    case reloaded(ServiceID, pid: pid_t)
}

public enum SupervisorError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownService(ServiceID)
    case notRunning(ServiceID)
    case notReloadable(ServiceID)
    case signalFailed(ServiceID, errno: Int32)

    public var description: String {
        switch self {
        case .unknownService(let id): return "\(id.displayName) is not managed by the supervisor"
        case .notRunning(let id): return "\(id.displayName) is not running"
        case .notReloadable(let id): return "\(id.displayName) does not support graceful reload"
        case .signalFailed(let id, let e): return "Could not signal \(id.displayName): \(String(cString: strerror(e)))"
        }
    }
}
