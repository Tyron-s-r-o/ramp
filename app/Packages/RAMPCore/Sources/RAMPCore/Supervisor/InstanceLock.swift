import Foundation

/// Only one RAMP.app may supervise a given RAMP home: a second copy (e.g. a Debug build from Xcode next to
/// /Applications/RAMP.app) would start PHP-FPM / Apache / MySQL again and collide on sockets and ports.
///
/// Non-blocking `flock(2)` on `<root>/run/ramp-app.lock`, held for the life of the process; the kernel drops it
/// when the holder dies, so there are no stale locks. `O_CLOEXEC` keeps the descriptor out of the supervised
/// services (they must not hold the lock after the app is gone). The file carries the holder's PID.
public final class InstanceLock: Sendable {
    public let url: URL
    private let fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    public static func url(paths: Paths) -> URL {
        paths.runDir.appending(path: "ramp-app.lock", directoryHint: .notDirectory)
    }

    /// The lock, or `nil` when another live process holds it (see `holderPID`).
    public static func acquire(paths: Paths) -> InstanceLock? {
        acquire(at: url(paths: paths))
    }

    static func acquire(at url: URL) -> InstanceLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        ftruncate(fd, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        return InstanceLock(url: url, fd: fd)
    }

    /// PID written by the current holder (for the "RAMP už beží" message / activating that copy).
    public static func holderPID(paths: Paths) -> pid_t? {
        holderPID(at: url(paths: paths))
    }

    static func holderPID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
