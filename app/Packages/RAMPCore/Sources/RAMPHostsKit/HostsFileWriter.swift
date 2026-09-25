import Darwin
import Foundation

/// Applies the RAMP block to a hosts file atomically (temp file in the same directory + `rename(2)`).
/// Used by the privileged helper with `systemHostsPath`; tests use temp files only.
public struct HostsFileWriter: Sendable {
    /// Real path of the system hosts file (`/etc` is a symlink to `/private/etc`).
    public static let systemHostsPath = "/private/etc/hosts"

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Current content of the hosts file (validated: regular file, ≤ 1 MiB, UTF-8).
    public func read() throws -> String {
        try readCurrent().content
    }

    /// Merges `names` into the file. Returns `true` when the file was rewritten, `false` when already up to date.
    @discardableResult
    public func apply(names: [String]) throws -> Bool {
        let current = try readCurrent()
        let merged = try HostsBlock.merge(existing: current.content, names: names)
        let newBytes = Array(merged.utf8)
        if newBytes.elementsEqual(current.content.utf8) { return false }
        try replace(with: newBytes, like: current.stat)
        return true
    }

    // MARK: - Internals

    private var filePath: String { path.path(percentEncoded: false) }

    private static func posixError(_ what: String, _ path: String, _ code: Int32 = errno) -> HostsError {
        .io("\(what) \(path): \(String(cString: strerror(code)))")
    }

    private func readCurrent() throws -> (content: String, stat: stat) {
        let p = filePath
        var st = stat()
        guard lstat(p, &st) == 0 else { throw Self.posixError("lstat", p) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw HostsError.notRegularFile }

        let fd = open(p, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw HostsError.notRegularFile }
            throw Self.posixError("open", p)
        }
        defer { close(fd) }
        guard fstat(fd, &st) == 0 else { throw Self.posixError("fstat", p) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw HostsError.notRegularFile }
        guard st.st_size <= off_t(HostsBlock.maxFileSize) else { throw HostsError.fileTooLarge }

        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("read", p)
            }
            if n == 0 { break }
            bytes.append(contentsOf: buffer[0..<n])
            if bytes.count > HostsBlock.maxFileSize { throw HostsError.fileTooLarge }
        }
        guard let content = String(validating: bytes, as: UTF8.self) else {
            throw HostsError.io("\(p) is not valid UTF-8; refusing to rewrite it")
        }
        return (content, st)
    }

    private func replace(with bytes: [UInt8], like original: stat) throws {
        let p = filePath
        let dir = path.deletingLastPathComponent().path(percentEncoded: false)
        let tmp = (dir.hasSuffix("/") ? dir : dir + "/") + ".hosts.ramp-\(UUID().uuidString)"

        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError("create", tmp) }
        var fdOpen = true
        var renamed = false
        defer {
            if fdOpen { close(fd) }
            if !renamed { unlink(tmp) }
        }

        // Same owner/group/mode as the original; chown is best-effort unless running as root.
        if fchown(fd, original.st_uid, original.st_gid) != 0, getuid() == 0 {
            throw Self.posixError("fchown", tmp)
        }
        guard fchmod(fd, original.st_mode & 0o7777) == 0 else { throw Self.posixError("fchmod", tmp) }

        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("write", tmp)
            }
            offset += n
        }
        guard fsync(fd) == 0 else { throw Self.posixError("fsync", tmp) }
        fdOpen = false
        guard close(fd) == 0 else { throw Self.posixError("close", tmp) }
        guard rename(tmp, p) == 0 else { throw Self.posixError("rename", p) }
        renamed = true

        // Persist the directory entry (best-effort).
        let dfd = open(dir, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
    }
}
