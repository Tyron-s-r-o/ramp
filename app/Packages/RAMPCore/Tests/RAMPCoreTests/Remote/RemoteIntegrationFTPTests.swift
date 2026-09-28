import Foundation
import Testing
@testable import RAMPCore

/// Against a throwaway pyftpdlib server (plain FTP + explicit TLS with a self-signed cert)
/// started by `Scripts/remote-it.sh`. Skipped unless RAMP_REMOTE_IT=1.
@Suite(.serialized, .enabled(if: RemoteIT.enabled))
struct RemoteIntegrationFTPTests {
    private func site(_ proto: RemoteProtocol, insecure: Bool = true, passive: Bool = true,
                      initialPath: String? = nil) -> RemoteSite {
        let port = RemoteIT.port(proto == .ftpes ? "RAMP_IT_FTPES_PORT" : "RAMP_IT_FTP_PORT")
        return RemoteSite(name: "it", proto: proto, host: "127.0.0.1", port: port,
                          username: RemoteIT.value("RAMP_IT_FTP_USER"), initialPath: initialPath,
                          passive: passive, allowInsecureCertificate: insecure)
    }

    private var secrets: SiteSecrets { SiteSecrets(password: RemoteIT.value("RAMP_IT_FTP_PASS")) }

    private func connect(_ site: RemoteSite) async throws -> any RemoteFileSystem {
        try await RemoteConnector.connect(site: site, secrets: secrets, knownHosts: try RemoteIT.tempKnownHosts())
    }

    @Test(arguments: [RemoteProtocol.ftp, .ftpes])
    func fullRoundTrip(_ proto: RemoteProtocol) async throws {
        let fs = try await connect(site(proto))
        defer { Task { await fs.close() } }
        #expect(fs is FTPFileSystem)
        #expect(try await fs.homeDirectory() == "/")
        try await RemoteIT.exerciseFileSystem(fs, base: "/")
    }

    @Test func activeMode() async throws {
        let fs = try await connect(site(.ftp, passive: false))
        defer { Task { await fs.close() } }
        let dir = "/active-\(UUID().uuidString.prefix(6))"
        try await fs.createDirectory(dir)
        #expect(try await fs.stat(dir)?.kind == .directory)
        #expect(try await fs.list(dir).isEmpty)
        try await fs.delete(RemoteItem(path: dir, name: RemotePath.name(dir), kind: .directory))
    }

    @Test func initialPathIsHome() async throws {
        let fs = try await connect(site(.ftp, initialPath: "/some/where"))
        #expect(try await fs.homeDirectory() == "/some/where")
        await fs.close()
    }

    @Test func wrongPasswordIsAuthenticationFailed() async throws {
        await #expect(throws: RemoteError.authenticationFailed) {
            _ = try await RemoteConnector.connect(site: site(.ftp), secrets: SiteSecrets(password: "nope"),
                                                  knownHosts: try RemoteIT.tempKnownHosts())
        }
        await #expect(throws: RemoteError.missingSecret) {
            _ = try await RemoteConnector.connect(site: site(.ftp), secrets: nil, knownHosts: try RemoteIT.tempKnownHosts())
        }
    }

    @Test func selfSignedCertificateRejectedUnlessAllowed() async throws {
        do {
            _ = try await connect(site(.ftpes, insecure: false))
            Issue.record("self-signed certificate accepted")
        } catch let error as RemoteError {
            guard case .certificateUntrusted = error else {
                Issue.record("expected certificateUntrusted, got \(error)")
                return
            }
        }
    }

    @Test func missingPathErrors() async throws {
        let fs = try await connect(site(.ftp))
        defer { Task { await fs.close() } }
        await #expect(throws: RemoteError.notFound("/no/such/dir")) { _ = try await fs.list("/no/such/dir") }
        #expect(try await fs.stat("/no-such-file.txt") == nil)
        await #expect(throws: RemoteError.self) {
            try await fs.delete(RemoteItem(path: "/no-such-file.txt", name: "no-such-file.txt", kind: .file))
        }
    }

    @Test func connectionRefused() async throws {
        var s = site(.ftp)
        s.port = 1
        await #expect(throws: RemoteError.self) { _ = try await connect(s) }
    }
}
