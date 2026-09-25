import Darwin
import Foundation

/// Long-running maintenance operations that must never overlap (plan 07-02).
public enum MaintenanceReason: String, Sendable, Codable, CaseIterable, CustomStringConvertible {
    case update, dump, mampImport, uninstall

    public var description: String {
        switch self {
        case .update: "update"
        case .dump: "MySQL dump"
        case .mampImport: "MAMP import"
        case .uninstall: "uninstall"
        }
    }
}

public enum MaintenanceError: Error, LocalizedError, Equatable, Sendable {
    /// Another maintenance operation holds the lock (`nil` = held by another process, reason unknown).
    case busy(MaintenanceReason?)

    public var errorDescription: String? {
        switch self {
        case .busy(let reason?): return "Another maintenance operation is running (\(reason)). Try again when it has finished."
        case .busy(nil): return "Another RAMP process is running a maintenance operation. Try again when it has finished."
        }
    }
}

/// Proof of holding the lock; pass it back to `release`.
public struct MaintenanceToken: Sendable, Hashable {
    public let id: UUID
    public let reason: MaintenanceReason
}

/// One global lock for updates, dumps, MAMP import and uninstall: `acquire` fails fast with `busy`.
///
/// In-process exclusion via the actor; with a `lockFile` also across processes (RAMP.app vs rampctl) through a
/// non-blocking `flock(2)` that the kernel drops when the holder dies (no stale locks).
public actor MaintenanceLock {
    private var holder: MaintenanceToken?
    private let lockFile: URL?
    private var fd: Int32 = -1

    public init(lockFile: URL? = nil) {
        self.lockFile = lockFile
    }

    /// Lock shared by everything that uses `paths` (file `<root>/run/maintenance.lock`).
    public init(paths: Paths) {
        self.init(lockFile: paths.runDir.appending(path: "maintenance.lock", directoryHint: .notDirectory))
    }

    public var current: MaintenanceReason? { holder?.reason }

    public func acquire(_ reason: MaintenanceReason) throws -> MaintenanceToken {
        if let holder { throw MaintenanceError.busy(holder.reason) }
        if let lockFile {
            let path = lockFile.path(percentEncoded: false)
            try? FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let handle = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard handle >= 0 else { throw MaintenanceError.busy(nil) }
            guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
                close(handle)
                throw MaintenanceError.busy(nil)
            }
            let text = "\(getpid()) \(reason.rawValue)\n"
            ftruncate(handle, 0)
            _ = text.withCString { write(handle, $0, strlen($0)) }
            fd = handle
        }
        let token = MaintenanceToken(id: UUID(), reason: reason)
        holder = token
        return token
    }

    public func release(_ token: MaintenanceToken) {
        guard holder == token else { return }
        holder = nil
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// acquire → body → release (also on error).
    public func withLock<T: Sendable>(_ reason: MaintenanceReason,
                                      _ body: @Sendable () async throws -> T) async throws -> T {
        let token = try acquire(reason)
        defer { release(token) }
        return try await body()
    }
}
