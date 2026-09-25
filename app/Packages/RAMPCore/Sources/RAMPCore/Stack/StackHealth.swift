import Foundation

/// Aggregate stack state for the main window badge and the menu-bar icon. Pure — see `evaluate`.
public struct StackHealth: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Every expected service is running.
        case allRunning
        /// Mix of running / starting / backing off / stopping / stopped.
        case partial
        /// At least one expected or optional service failed.
        case error
        /// None of the expected services is running, starting or backing off.
        case stopped
    }

    public var level: Level
    /// At least one PHP branch has Xdebug enabled.
    public var xdebugOn: Bool
    /// Failed services (expected or optional), sorted by name.
    public var failed: [ServiceID]

    public init(level: Level, xdebugOn: Bool = false, failed: [ServiceID] = []) {
        self.level = level
        self.xdebugOn = xdebugOn
        self.failed = failed
    }

    /// - Parameters:
    ///   - states: current supervisor states (missing = stopped).
    ///   - expected: services that should be running (installed + autostart).
    ///   - optional: services that may be stopped without degrading the stack (Elasticsearch).
    ///   - xdebugBranches: PHP branches with Xdebug enabled.
    public static func evaluate(states: [ServiceID: ServiceState], expected: Set<ServiceID>,
                                optional: Set<ServiceID> = [], xdebugBranches: [String] = []) -> StackHealth {
        func state(_ id: ServiceID) -> ServiceState { states[id] ?? .stopped }
        let failed = expected.union(optional)
            .filter { if case .failed = state($0) { true } else { false } }
            .sorted { $0.name < $1.name }
        let xdebug = !xdebugBranches.isEmpty
        if !failed.isEmpty { return StackHealth(level: .error, xdebugOn: xdebug, failed: failed) }
        if expected.allSatisfy({ state($0).isRunning }) {
            return StackHealth(level: .allRunning, xdebugOn: xdebug)
        }
        let anyAlive = expected.contains { id in
            switch state(id) {
            case .running, .starting, .backingOff: return true
            case .stopped, .stopping, .failed: return false
            }
        }
        return StackHealth(level: anyAlive ? .partial : .stopped, xdebugOn: xdebug)
    }
}
