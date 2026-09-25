import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// Raw listening socket on 127.0.0.1:<ephemeral> owned by the test process.
final class TestListener {
    let fd: Int32
    let port: Int

    init(listen: Bool = true) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = 0
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        if listen { Darwin.listen(fd, 8) }
        self.fd = fd
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: out.sin_port))
    }

    private var closed = false
    func close() { if !closed { closed = true; Darwin.close(fd) } }
    deinit { close() }

    /// A port that was free a moment ago.
    static func freePort() throws -> Int {
        let l = try TestListener(listen: false)
        let p = l.port
        l.close()
        return p
    }
}

@Suite struct PortProbeTests {
    @Test func freePortIsFree() throws {
        let port = try TestListener.freePort()
        #expect(PortProbe.check(port: port) == .free)
    }

    @Test func listeningPortReportsOwnPID() throws {
        let l = try TestListener()
        defer { l.close() }
        guard case .inUse(let c) = PortProbe.check(port: l.port, serviceName: "Redis") else {
            Issue.record("expected conflict"); return
        }
        #expect(c.pid == getpid())
        #expect(c.executablePath == PortProbe.executablePath(pid: getpid()))
        #expect(c.processName?.isEmpty == false)
        #expect(c.description.contains("Port \(l.port) is used by"))
        #expect(c.description.contains("PID \(getpid())"))
        #expect(c.description.contains("change the Redis port in RAMP"))
    }

    @Test func ownerUnderRootIsOwnOrphan() throws {
        let l = try TestListener()
        defer { l.close() }
        let exe = try #require(PortProbe.executablePath(pid: getpid()))
        let root = URL(filePath: exe).deletingLastPathComponent()
        #expect(PortProbe.check(port: l.port, ownRoot: root) == .ownOrphan(pid: getpid(), executablePath: exe))
        // sibling directory with a common prefix is NOT our root
        var rootPath = root.path(percentEncoded: false)
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        let fake = URL(filePath: String(rootPath.dropLast()), directoryHint: .isDirectory)
        if case .ownOrphan = PortProbe.check(port: l.port, ownRoot: fake) { Issue.record("prefix match leaked") }
    }

    @Test func mampConflictMessageNamesMAMP() {
        let c = PortConflict(port: 80, pid: 812, processName: "httpd",
                             executablePath: "/Applications/MAMP/Library/bin/httpd", serviceName: "Apache")
        #expect(c.description == "Port 80 is used by httpd (PID 812, /Applications/MAMP/Library/bin/httpd). "
                + "Quit MAMP PRO or change the Apache port in RAMP.")
        let invisible = PortConflict(port: 3306, serviceName: "MySQL")
        #expect(invisible.description.contains("MAMP PRO"))
        #expect(invisible.description.contains("change the MySQL port"))
    }

    @Test func isUnderIsComponentWise() {
        let root = URL(filePath: "/tmp/a b/RAMP", directoryHint: .isDirectory)
        #expect(PortProbe.isUnder("/tmp/a b/RAMP/php/8.3/current/sbin/php-fpm", root: root))
        #expect(!PortProbe.isUnder("/tmp/a b/RAMPX/bin/x", root: root))
        #expect(!PortProbe.isUnder("/bin/sleep", root: root))
    }
}
