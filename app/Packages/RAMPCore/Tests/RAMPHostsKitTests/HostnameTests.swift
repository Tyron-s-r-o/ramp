import Testing
@testable import RAMPHostsKit

@Suite("Hostname validation")
struct HostnameTests {
    static let label63 = String(repeating: "a", count: 63)
    /// 63 + 1 + 63 + 1 + 63 + 1 + 61 = 253
    static let total253 = [label63, label63, label63, String(repeating: "b", count: 61)].joined(separator: ".")

    @Test("valid names are accepted and normalized", arguments: [
        ("asteel.local", "asteel.local"),
        ("admin.asteel.local", "admin.asteel.local"),
        ("api2.hladamchatu.local", "api2.hladamchatu.local"),
        ("front-asteel.local", "front-asteel.local"),
        ("a.b", "a.b"),
        ("  Front.ASteel.Local.  ", "front.asteel.local"),
        ("asteel.local.", "asteel.local"),
        ("xn--bcher-kva.local", "xn--bcher-kva.local"),
        ("3com.local", "3com.local"),
    ])
    func valid(input: String, expected: String) throws {
        #expect(try Hostname.validate(input) == expected)
    }

    @Test("63-char label and 253-char total accepted")
    func lengthLimits() throws {
        #expect(try Hostname.validate("\(Self.label63).local") == "\(Self.label63).local")
        #expect(Self.total253.count == 253)
        #expect(try Hostname.validate(Self.total253) == Self.total253)
    }

    @Test("invalid names are rejected", arguments: [
        "", "   ", ".", "asteel", "a..b", ".asteel.local", "asteel.local..",
        "-front.local", "front-.local", "front.-local",
        "under_score.local", "*.asteel.local", "a*.local",
        "front asteel.local", "front\tasteel.local", "front#.local",
        "front\n.local", "front.local\nevil.local", "front\r.local", "front\0.local",
        "bücher.local", "фронт.local",
        "127.0.0.1", "::1", "[::1]", "fe80::1", "foo.123", "10.0.0.1",
        "a:b.local", "a/b.local", "a\\b.local",
    ])
    func invalid(input: String) {
        #expect(throws: HostsError.invalidHostname(input)) {
            try Hostname.validate(input)
        }
    }

    @Test("too long label / total rejected")
    func tooLong() {
        let label64 = String(repeating: "a", count: 64) + ".local"
        #expect(throws: HostsError.invalidHostname(label64)) { try Hostname.validate(label64) }
        let total254 = Self.total253 + "b"
        #expect(throws: HostsError.invalidHostname(total254)) { try Hostname.validate(total254) }
    }

    @Test("reserved names rejected", arguments: [
        ("localhost.localdomain", "localhost.localdomain"),
        ("LOCALHOST.localdomain", "localhost.localdomain"),
        ("foo.localhost", "foo.localhost"),
        ("a.b.localhost", "a.b.localhost"),
        ("localhost.", "localhost"),
        ("IP6-Loopback", "ip6-loopback"),
    ])
    func reservedNormalized(input: String, normalized: String) {
        #expect(throws: HostsError.reservedName(normalized)) { try Hostname.validate(input) }
    }

    @Test("reserved error for dotted reserved names")
    func reservedError() {
        #expect(throws: HostsError.reservedName("localhost.localdomain")) {
            try Hostname.validate("localhost.localdomain")
        }
        #expect(throws: HostsError.reservedName("foo.localhost")) {
            try Hostname.validate("Foo.localhost")
        }
    }

    @Test("single-label reserved names are rejected with reservedName", arguments: [
        "localhost", "broadcasthost", "ip6-localhost", "ip6-loopback",
    ])
    func reservedSingle(input: String) {
        #expect(throws: HostsError.reservedName(input)) { try Hostname.validate(input) }
    }

    @Test("maxNames constant")
    func maxNames() {
        #expect(Hostname.maxNames == 2000)
    }
}
