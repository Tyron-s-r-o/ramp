import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Testing
@testable import RAMPCore

/// Against a throwaway `/usr/sbin/sshd` started by `Scripts/remote-it.sh` (key auth only,
/// runs as the current user). Skipped unless RAMP_REMOTE_IT=1.
@Suite(.serialized, .enabled(if: RemoteIT.enabled))
struct RemoteIntegrationSFTPTests {
    private var port: Int { RemoteIT.port("RAMP_IT_SSH_PORT") }
    private var base: String { RemoteIT.value("RAMP_IT_SFTP_ROOT") }

    private func site(key: String, initialPath: String? = nil) -> RemoteSite {
        RemoteSite(name: "it", proto: .sftp, host: "127.0.0.1", port: port, username: RemoteIT.value("RAMP_IT_SSH_USER"),
                   auth: .privateKey, privateKeyPath: RemoteIT.value(key), initialPath: initialPath)
    }

    /// Trusts the sandbox host key so the other tests can connect.
    private func trustedHosts() throws -> KnownHosts {
        let kh = try RemoteIT.tempKnownHosts()
        try kh.trust(host: "127.0.0.1", port: port, fingerprint: RemoteIT.value("RAMP_IT_SSH_HOSTKEY_FP"))
        return kh
    }

    @Test func hostKeyUnknownTrustAndMismatch() async throws {
        let kh = try RemoteIT.tempKnownHosts()
        let s = site(key: "RAMP_IT_KEY_ED25519")
        let expected = RemoteIT.value("RAMP_IT_SSH_HOSTKEY_FP")
        await #expect(throws: RemoteError.unknownHostKey(host: "127.0.0.1", port: port, fingerprint: expected)) {
            _ = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: kh)
        }
        try kh.trust(host: "127.0.0.1", port: port, fingerprint: expected)
        let fs = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: kh)
        #expect(try await fs.homeDirectory() == NSHomeDirectory())
        await fs.close()

        try kh.trust(host: "127.0.0.1", port: port, fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        await #expect(throws: RemoteError.hostKeyMismatch(host: "127.0.0.1", port: port,
                                                         expected: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                                                         actual: expected)) {
            _ = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: kh)
        }
    }

    @Test func fullRoundTripEd25519() async throws {
        let fs = try await RemoteConnector.connect(site: site(key: "RAMP_IT_KEY_ED25519", initialPath: base),
                                                   secrets: nil, knownHosts: try trustedHosts())
        defer { Task { await fs.close() } }
        #expect(fs is SFTPFileSystem)
        #expect(try await fs.homeDirectory() == base)
        try await RemoteIT.exerciseFileSystem(fs, base: base)
    }

    @Test func encryptedKeyNeedsPassphrase() async throws {
        let kh = try trustedHosts()
        let s = site(key: "RAMP_IT_KEY_ED25519_ENC")
        await #expect(throws: RemoteError.missingSecret) {
            _ = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: kh)
        }
        await #expect(throws: RemoteError.self) {
            _ = try await RemoteConnector.connect(site: s, secrets: SiteSecrets(keyPassphrase: "wrong"), knownHosts: kh)
        }
        let fs = try await RemoteConnector.connect(site: s, secrets: SiteSecrets(keyPassphrase: RemoteIT.value("RAMP_IT_KEY_PASSPHRASE")),
                                                   knownHosts: kh)
        _ = try await fs.list(base)
        await fs.close()
    }

    /// sshd runs with the default PubkeyAcceptedAlgorithms (no SHA-1 "ssh-rsa"), so this only
    /// passes when the RSA signature is rsa-sha2-512/256 (RFC 8332).
    @Test func rsaKey() async throws {
        let fs = try await RemoteConnector.connect(site: site(key: "RAMP_IT_KEY_RSA", initialPath: base), secrets: nil,
                                                   knownHosts: try trustedHosts())
        defer { Task { await fs.close() } }
        #expect(try await fs.homeDirectory() == base)
        try await RemoteIT.exerciseFileSystem(fs, base: base)
    }

    @Test func encryptedRSAKey() async throws {
        let kh = try trustedHosts()
        let s = site(key: "RAMP_IT_KEY_RSA_ENC")
        await #expect(throws: RemoteError.missingSecret) {
            _ = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: kh)
        }
        await #expect(throws: RemoteError.self) {
            _ = try await RemoteConnector.connect(site: s, secrets: SiteSecrets(keyPassphrase: "wrong"), knownHosts: kh)
        }
        let fs = try await RemoteConnector.connect(site: s, secrets: SiteSecrets(keyPassphrase: RemoteIT.value("RAMP_IT_KEY_PASSPHRASE")),
                                                   knownHosts: kh)
        _ = try await fs.list(base)
        await fs.close()
    }

    @Test func unauthorizedKeyFails() async throws {
        await #expect(throws: RemoteError.authenticationFailed) {
            _ = try await RemoteConnector.connect(site: site(key: "RAMP_IT_KEY_UNAUTHORIZED"), secrets: nil,
                                                  knownHosts: try trustedHosts())
        }
    }

    @Test func pemKeyGivesClearError() async throws {
        await #expect(throws: RemoteError.self) {
            _ = try await RemoteConnector.connect(site: site(key: "RAMP_IT_KEY_PEM"), secrets: nil, knownHosts: try trustedHosts())
        }
        do {
            _ = try await RemoteConnector.connect(site: site(key: "RAMP_IT_KEY_PEM"), secrets: nil, knownHosts: try trustedHosts())
        } catch let RemoteError.protocolError(message) {
            #expect(message.contains("PEM"))
        }
    }

    @Test func connectionRefused() async throws {
        var s = site(key: "RAMP_IT_KEY_ED25519")
        s.port = 1
        await #expect(throws: RemoteError.self) {
            _ = try await RemoteConnector.connect(site: s, secrets: nil, knownHosts: try trustedHosts())
        }
    }

    // MARK: Password auth (in-process Citadel server; system sshd needs root/PAM for passwords)

    @Test func passwordAuthAgainstCitadelServer() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let itPort = RemoteIT.port("RAMP_IT_CITADEL_PORT")
        let server = try await SSHServer.host(host: "127.0.0.1", port: itPort,
                                              hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
                                              authenticationDelegate: PasswordOnly(username: "u", password: "p"))
        let kh = try RemoteIT.tempKnownHosts()
        let fp = KnownHosts.fingerprint(openSSHPublicKey: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: hostKey).publicKey))!
        try kh.trust(host: "127.0.0.1", port: itPort, fingerprint: fp)
        let s = RemoteSite(name: "pw", proto: .sftp, host: "127.0.0.1", port: itPort, username: "u")

        await #expect(throws: RemoteError.authenticationFailed) {
            _ = try await SFTPFileSystem.connect(site: s, secrets: SiteSecrets(password: "bad"), knownHosts: kh)
        }
        await #expect(throws: RemoteError.missingSecret) {
            _ = try await SFTPFileSystem.connect(site: s, secrets: nil, knownHosts: kh)
        }
        // Right password: authentication passes; this server has no SFTP subsystem, so the
        // failure (if any) must be something other than an auth error.
        do {
            let fs = try await SFTPFileSystem.connect(site: s, secrets: SiteSecrets(password: "p"), knownHosts: kh)
            await fs.close()
        } catch {
            #expect(error as? RemoteError != .authenticationFailed)
        }
        try? await server.close()
    }
}

private struct PasswordOnly: NIOSSHServerUserAuthenticationDelegate {
    let username: String
    let password: String
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(.init(password: password)) = request.request, request.username == username {
            return responsePromise.succeed(.success)
        }
        responsePromise.succeed(.failure)
    }
}

/// Read-only smoke test against a real server (never writes). Enable with
/// RAMP_REMOTE_SMOKE_HOST, _USER, _KEY, _PATH (+ optional _PORT, _PASSPHRASE).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RAMP_REMOTE_SMOKE_HOST"] != nil))
struct RemoteIntegrationSmokeTests {
    @Test func listRealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let site = RemoteSite(name: "smoke", proto: .sftp, host: env["RAMP_REMOTE_SMOKE_HOST"]!,
                              port: Int(env["RAMP_REMOTE_SMOKE_PORT"] ?? "22"), username: env["RAMP_REMOTE_SMOKE_USER"] ?? "",
                              auth: .privateKey, privateKeyPath: env["RAMP_REMOTE_SMOKE_KEY"])
        let secrets = SiteSecrets(keyPassphrase: env["RAMP_REMOTE_SMOKE_PASSPHRASE"])
        let kh = try RemoteIT.tempKnownHosts()
        // Trust on first use (the fingerprint is printed for manual comparison).
        do {
            _ = try await RemoteConnector.connect(site: site, secrets: secrets, knownHosts: kh)
        } catch let RemoteError.unknownHostKey(host, port, fp) {
            print("smoke: host key \(host):\(port) \(fp)")
            try kh.trust(host: host, port: port, fingerprint: fp)
        }
        let fs = try await RemoteConnector.connect(site: site, secrets: secrets, knownHosts: kh)
        let items = try await fs.list(env["RAMP_REMOTE_SMOKE_PATH"] ?? "/")
        print("smoke: home=\(try await fs.homeDirectory()) entries=\(items.count) dirs=\(items.filter { $0.kind == .directory }.count)")
        #expect(!items.isEmpty)
        await fs.close()
    }
}
