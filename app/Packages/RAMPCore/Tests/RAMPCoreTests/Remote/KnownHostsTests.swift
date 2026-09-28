import Foundation
import Testing
@testable import RAMPCore

struct KnownHostsTests {
    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ramp-kh-\(UUID().uuidString)")
        return dir.appending(path: "remote/known_hosts.json")
    }

    @Test func trustPersistsAndReloads() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let kh = KnownHosts(fileURL: url)
        #expect(kh.fingerprint(host: "example.com", port: 22) == nil)

        try kh.trust(host: "Example.COM", port: 22, fingerprint: "SHA256:abc")
        try kh.trust(host: "example.com", port: 2222, fingerprint: "SHA256:def")
        #expect(kh.fingerprint(host: "example.com", port: 22) == "SHA256:abc")

        let reloaded = KnownHosts(fileURL: url)
        #expect(reloaded.fingerprint(host: "example.com", port: 22) == "SHA256:abc")
        #expect(reloaded.fingerprint(host: "example.com", port: 2222) == "SHA256:def")
        #expect(reloaded.all.count == 2)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func trustReplacesAndForgetRemoves() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let kh = KnownHosts(fileURL: url)
        try kh.trust(host: "h", port: 22, fingerprint: "SHA256:old")
        try kh.trust(host: "h", port: 22, fingerprint: "SHA256:new")
        #expect(kh.fingerprint(host: "h", port: 22) == "SHA256:new")
        try kh.forget(host: "h", port: 22)
        try kh.forget(host: "h", port: 22) // no-op
        #expect(kh.fingerprint(host: "h", port: 22) == nil)
        #expect(KnownHosts(fileURL: url).fingerprint(host: "h", port: 22) == nil)
        // No temp files left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
        #expect(left == ["known_hosts.json"])
    }

    @Test func corruptFileMeansEmpty() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(KnownHosts(fileURL: url).all.isEmpty)
    }

    @Test func ipv6KeysAreBracketed() {
        #expect(KnownHosts.key("::1", 22) == "[::1]:22")
        #expect(KnownHosts.key("Host", 22) == "host:22")
    }

    @Test func fingerprintMatchesSshKeygen() {
        // `ssh-keygen -lf` → 256 SHA256:/QjhqMtm1/pfiRbo9g+5aLR2yCHVikO7YgFvUViLV6Y test (ED25519)
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORfyUXJjKTsO36S6aYQvC2WXYjXBklULfHAW0lFhUnR test"
        #expect(KnownHosts.fingerprint(openSSHPublicKey: line) == "SHA256:/QjhqMtm1/pfiRbo9g+5aLR2yCHVikO7YgFvUViLV6Y")
        #expect(KnownHosts.fingerprint(openSSHPublicKey: "garbage") == nil)
    }
}
