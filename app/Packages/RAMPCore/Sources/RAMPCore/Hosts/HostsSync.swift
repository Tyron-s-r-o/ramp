import Foundation
import RAMPHostsKit
import Synchronization

/// How the RAMP block in the hosts file was brought in sync.
public enum HostsSyncChannel: String, Sendable, Equatable {
    /// Privileged helper (SMAppService daemon) over XPC — no prompt.
    case helper
    /// `osascript … with administrator privileges` — password prompt.
    case adminPrompt
    /// Plain file write (user-owned hosts file, tests / `RAMP_HOSTS_FILE`).
    case direct
}

public enum HostsSyncOutcome: Sendable, Equatable {
    /// The hosts file already contained exactly this block — nothing privileged was run.
    case unchanged
    case updated(via: HostsSyncChannel)
}

public enum HostsSyncError: Error, Equatable, LocalizedError {
    /// The user dismissed the administrator password prompt.
    case cancelled
    /// No reply from the helper within the timeout.
    case timeout
    /// The helper path cannot be used (unsigned / ad-hoc build, helper not enabled).
    case helperUnavailable(String)
    /// The helper replied with an error text or the XPC connection failed.
    case helperFailed(String)
    /// osascript / install failed.
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Updating /etc/hosts was cancelled"
        case .timeout: return "The hosts helper did not reply in time"
        case .helperUnavailable(let why): return "Hosts helper unavailable: \(why)"
        case .helperFailed(let why): return "Hosts helper failed: \(why)"
        case .commandFailed(let why): return "Updating /etc/hosts failed: \(why)"
        }
    }
}

/// Keeps the `# RAMP BEGIN/END` block of the hosts file equal to `names`.
public protocol HostsSyncing: Sendable {
    func apply(names: [String]) async throws -> HostsSyncOutcome
}

/// SMAppService daemon state, reduced to what the app needs.
public enum HelperStatus: String, Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

/// A privileged helper path that is only usable in some states (see `HelperHostsSync`).
public protocol PrivilegedHostsSyncing: HostsSyncing {
    var status: HelperStatus { get async }
}

/// Front door for hosts sync: reads the (world-readable) hosts file first and returns `.unchanged` without
/// any privileged call or password prompt when the block is already correct; otherwise uses the helper when
/// it is enabled, else the fallback (password prompt).
public struct HostsSyncCoordinator: HostsSyncing {
    public typealias Reader = @Sendable () throws -> String

    private let helper: (any PrivilegedHostsSyncing)?
    private let fallback: any HostsSyncing
    private let reader: Reader

    public init(helper: (any PrivilegedHostsSyncing)?, fallback: any HostsSyncing,
                reader: @escaping Reader = HostsSyncCoordinator.systemReader) {
        self.helper = helper
        self.fallback = fallback
        self.reader = reader
    }

    /// Reads `/private/etc/hosts` (the path constant lives in RAMPHostsKit).
    public static let systemReader: Reader = {
        try HostsFileWriter(path: URL(filePath: HostsFileWriter.systemHostsPath)).read()
    }

    /// `true` when the hosts file already holds exactly the block for `names`.
    public func isInSync(names: [String]) throws -> Bool {
        let current = try reader()
        return try HostsBlock.merge(existing: current, names: names) == current
    }

    public func apply(names: [String]) async throws -> HostsSyncOutcome {
        if try isInSync(names: names) { return .unchanged }
        if let helper, await helper.status == .enabled {
            return try await helper.apply(names: names)
        }
        return try await fallback.apply(names: names)
    }
}

/// Writes a user-owned hosts file directly (no privileges). For tests and `RAMP_HOSTS_FILE`, never
/// used for the system file.
public struct DirectHostsSync: HostsSyncing {
    public let path: URL

    public init(path: URL) { self.path = path }

    public func read() throws -> String {
        try HostsFileWriter(path: path).read()
    }

    public func apply(names: [String]) async throws -> HostsSyncOutcome {
        try HostsFileWriter(path: path).apply(names: names) ? .updated(via: .direct) : .unchanged
    }
}

// MARK: - Reply timeout

/// Resumes a continuation exactly once — whichever of reply / error handler / timeout comes first wins,
/// later calls are ignored.
final class OneShot<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// Returns `true` only for the call that actually resumed.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        guard let c = continuation.withLock({ value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }) else { return false }
        c.resume(with: result)
        return true
    }
}

/// Bridges a callback API to async with a timeout (`HostsSyncError.timeout`). `body` gets the one-shot
/// to resume from any thread; a reply after the timeout is dropped.
func withReplyTimeout<T: Sendable>(_ timeout: Duration,
                                   _ body: @Sendable (OneShot<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
        let shot = OneShot(c)
        let nanos = Int(min(timeout.components.seconds, 3600)) * 1_000_000_000
            + Int(timeout.components.attoseconds / 1_000_000_000)
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanos)) {
            shot.resume(.failure(HostsSyncError.timeout))
        }
        body(shot)
    }
}
