import Darwin
import Foundation

/// A TCP port that RAMP needs is taken by another process.
public struct PortConflict: Error, Sendable, Equatable, CustomStringConvertible {
    public var port: Int
    /// Owner, if visible (`lsof` cannot see processes of other users, e.g. MAMP PRO's root httpd).
    public var pid: pid_t?
    public var processName: String?
    public var executablePath: String?
    /// Human service name for the hint, e.g. "Apache", "MySQL".
    public var serviceName: String?
    /// errno of the failed bind (EADDRINUSE / EACCES).
    public var bindErrno: Int32

    public init(port: Int, pid: pid_t? = nil, processName: String? = nil, executablePath: String? = nil,
                serviceName: String? = nil, bindErrno: Int32 = EADDRINUSE) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.executablePath = executablePath
        self.serviceName = serviceName
        self.bindErrno = bindErrno
    }

    public var isMAMP: Bool {
        (executablePath ?? "").contains("/Applications/MAMP") || (processName ?? "").contains("MAMP")
    }

    public var description: String {
        let change = "change the \(serviceName.map { "\($0) " } ?? "")port in RAMP"
        if bindErrno == EACCES {
            return "RAMP is not allowed to listen on port \(port) (permission denied). Choose a port above 1023 or \(change)."
        }
        guard let pid else {
            return "Port \(port) is already in use by another process (owner not visible — possibly running as "
                + "root, e.g. MAMP PRO). Quit it or \(change)."
        }
        var who = "Port \(port) is used by \(processName ?? "an unknown process") (PID \(pid)"
        if let executablePath { who += ", \(executablePath)" }
        who += ")."
        return isMAMP ? "\(who) Quit MAMP PRO or \(change)." : "\(who) Stop it or \(change)."
    }
}

public enum PortStatus: Sendable, Equatable {
    case free
    case inUse(PortConflict)
    /// The listener is a leftover RAMP process (executable under `Paths.root`) — safe to kill.
    case ownOrphan(pid: pid_t, executablePath: String)
}

/// Checks whether a TCP port can be bound and, if not, who owns it.
public enum PortProbe {
    /// Tries `bind` on each address (no SO_REUSEADDR/SO_REUSEPORT, so a wildcard listener such as
    /// MAMP's `*:80` is detected too). `ownRoot` identifies RAMP's own orphans.
    public static func check(port: Int, addresses: [String] = ["127.0.0.1"], ownRoot: URL? = nil,
                             serviceName: String? = nil) -> PortStatus {
        // Privileged port + loopback-only: the service really binds the wildcard address (macOS denies
        // non-root binds of 127.0.0.1:<1024 but allows *:<1024 — see ApacheConfigGenerator), so probe that.
        let probeAddresses = ApacheConfigGenerator.needsWildcardListen(port: port, addresses: addresses)
            ? ["0.0.0.0"] : addresses
        for address in probeAddresses {
            let err = bindErrno(port: port, address: address)
            guard err == EADDRINUSE || err == EACCES else { continue } // 0, or address unavailable (no ::1)
            if err == EACCES {
                return .inUse(PortConflict(port: port, serviceName: serviceName, bindErrno: EACCES))
            }
            if let owner = listeningOwner(port: port) {
                let exe = executablePath(pid: owner.pid)
                if let exe, let ownRoot, isUnder(exe, root: ownRoot) {
                    return .ownOrphan(pid: owner.pid, executablePath: exe)
                }
                return .inUse(PortConflict(port: port, pid: owner.pid, processName: owner.name,
                                           executablePath: exe, serviceName: serviceName))
            }
            // Bind failed but no visible listener: either an invisible (other user's) listener or
            // only TIME_WAIT leftovers. A successful connect proves a listener.
            if SocketAddress.canConnectTCP(host: address, port: port) {
                return .inUse(PortConflict(port: port, serviceName: serviceName))
            }
        }
        return .free
    }

    /// errno of a plain `bind` on `address:port` (0 = bindable).
    public static func bindErrno(port: Int, address: String) -> Int32 {
        guard let sa = SocketAddress(host: address, port: port) else { return EADDRNOTAVAIL }
        let fd = socket(sa.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        if sa.family == AF_INET6 {
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        let rc = sa.withSockaddr { bind(fd, $0, $1) }
        return rc == 0 ? 0 : errno
    }

    /// First process LISTENing on `port` visible to `lsof` (same user, or everything when root).
    public static func listeningOwner(port: Int) -> (pid: pid_t, name: String)? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var pid: pid_t?
        var name = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") {
                if pid != nil { break }
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("c"), pid != nil, name.isEmpty {
                name = String(line.dropFirst())
            }
        }
        guard let pid else { return nil }
        return (pid, name.isEmpty ? "unknown" : name)
    }

    /// Executable path of a process via `proc_pidpath` (nil if gone / not permitted).
    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Component-wise prefix check (`/a/bc` is not under `/a/b`).
    static func isUnder(_ path: String, root: URL) -> Bool {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let p = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPrefix = r.hasSuffix("/") ? r : r + "/"
        return p.hasPrefix(rootPrefix)
    }
}

/// IPv4/IPv6 literal socket address + AF_UNIX helpers (no DNS).
struct SocketAddress {
    let family: Int32
    private var storage = sockaddr_storage()
    private let length: socklen_t

    init?(host: String, port: Int) {
        guard (0...65535).contains(port) else { return nil }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if bare.contains(":") {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, bare, &sa.sin6_addr) == 1 else { return nil }
            family = AF_INET6
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeBytes(of: sa) { src in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) }
            }
        } else {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET, bare, &sa.sin_addr) == 1 else { return nil }
            family = AF_INET
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeBytes(of: sa) { src in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) }
            }
        }
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafeBytes(of: storage) { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), length)
        }
    }

    /// Blocking connect to a local literal address (loopback refuses immediately).
    static func canConnectTCP(host: String, port: Int) -> Bool {
        guard let sa = SocketAddress(host: host, port: port) else { return false }
        let fd = socket(sa.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return sa.withSockaddr { connect(fd, $0, $1) } == 0
    }

    /// Connect to a unix-domain stream socket.
    static func canConnectUnix(path: String) -> Bool {
        var sa = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sa.sun_path) else { return false }
        sa.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        sa.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &sa.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }
}
