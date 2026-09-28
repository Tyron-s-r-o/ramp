import Foundation
import Testing
@testable import RAMPCore

@Suite struct SiteVaultTests {
    private func tempVault(iterations: Int = 1_000) -> (SiteVault, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ramp-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = dir.appending(path: "remote/vault.json")
        return (SiteVault(url: url, iterations: iterations), dir)
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
    }

    @Test func setupStoreAndReadBack() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!vault.isInitialized)
        #expect(!vault.isUnlocked)
        try vault.setup(masterPassword: "correct horse")
        #expect(vault.isInitialized)
        #expect(vault.isUnlocked)

        let id = UUID()
        try vault.setSecrets(SiteSecrets(password: "s3cr3t-ľšč", keyPassphrase: "pp"), for: id)
        #expect(try vault.secrets(for: id) == SiteSecrets(password: "s3cr3t-ľšč", keyPassphrase: "pp"))
        #expect(try vault.secrets(for: UUID()) == nil)

        // A second instance reading the same file.
        let other = SiteVault(url: vault.url, iterations: 1_000)
        #expect(other.isInitialized)
        #expect(!other.isUnlocked)
        try other.unlock(masterPassword: "correct horse")
        #expect(try other.secrets(for: id)?.password == "s3cr3t-ľšč")
    }

    @Test func fileFormatAndPermissions() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try vault.setup(masterPassword: "pw")
        let id = UUID()
        try vault.setSecrets(SiteSecrets(password: "PLAINTEXT-MARKER"), for: id)

        let raw = try Data(contentsOf: vault.url)
        #expect(!String(decoding: raw, as: UTF8.self).contains("PLAINTEXT-MARKER"))
        let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["kdf"] as? String == "pbkdf2-sha256")
        #expect(json["iterations"] as? Int == 1_000)
        let saltB64 = try #require(json["salt"] as? String)
        #expect((Data(base64Encoded: saltB64)?.count ?? 0) >= 16)
        let checkB64 = try #require(json["check"] as? String)
        #expect(Data(base64Encoded: checkB64) != nil)
        let secrets = try #require(json["secrets"] as? [String: String])
        #expect(secrets.keys.sorted() == [id.uuidString])

        #expect(try posixPermissions(vault.url) == 0o600)
        #expect(try posixPermissions(vault.url.deletingLastPathComponent()) == 0o700)
    }

    @Test func lockAndWrongPassword() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try vault.setup(masterPassword: "right")
        let id = UUID()
        try vault.setSecrets(SiteSecrets(password: "x"), for: id)
        vault.lock()
        #expect(!vault.isUnlocked)
        #expect(throws: RemoteError.vaultLocked) { try vault.secrets(for: id) }
        #expect(throws: RemoteError.vaultLocked) { try vault.setSecrets(SiteSecrets(), for: id) }
        #expect(throws: RemoteError.vaultLocked) { try vault.removeSecrets(for: id) }
        #expect(throws: RemoteError.wrongMasterPassword) { try vault.unlock(masterPassword: "wrong") }
        #expect(throws: RemoteError.wrongMasterPassword) { try vault.unlock(masterPassword: "") }
        #expect(!vault.isUnlocked)
        try vault.unlock(masterPassword: "right")
        #expect(try vault.secrets(for: id)?.password == "x")
    }

    @Test func emptyPasswordAndDoubleSetupRejected() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: RemoteError.self) { try vault.setup(masterPassword: "") }
        #expect(!vault.isInitialized)
        try vault.setup(masterPassword: "a")
        #expect(throws: RemoteError.self) { try vault.setup(masterPassword: "b") }
        #expect(throws: RemoteError.self) { try vault.changeMasterPassword(old: "a", new: "") }
    }

    @Test func removeSecrets() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try vault.setup(masterPassword: "pw")
        let a = UUID(), b = UUID()
        try vault.setSecrets(SiteSecrets(password: "a"), for: a)
        try vault.setSecrets(SiteSecrets(password: "b"), for: b)
        try vault.removeSecrets(for: a)
        try vault.removeSecrets(for: UUID())
        #expect(try vault.secrets(for: a) == nil)
        #expect(try vault.secrets(for: b)?.password == "b")
    }

    @Test func changeMasterPasswordReencrypts() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try vault.setup(masterPassword: "old")
        let id = UUID()
        try vault.setSecrets(SiteSecrets(password: "keep me"), for: id)
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.url)) as? [String: Any]

        #expect(throws: RemoteError.wrongMasterPassword) { try vault.changeMasterPassword(old: "nope", new: "new") }
        try vault.changeMasterPassword(old: "old", new: "new")
        #expect(vault.isUnlocked)
        #expect(try vault.secrets(for: id)?.password == "keep me")

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.url)) as? [String: Any]
        #expect(before?["salt"] as? String != after?["salt"] as? String)

        vault.lock()
        #expect(throws: RemoteError.wrongMasterPassword) { try vault.unlock(masterPassword: "old") }
        try vault.unlock(masterPassword: "new")
        #expect(try vault.secrets(for: id)?.password == "keep me")
    }

    @Test func resetForgetsEverything() throws {
        let (vault, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try vault.setup(masterPassword: "pw")
        try vault.setSecrets(SiteSecrets(password: "x"), for: UUID())
        try vault.reset()
        #expect(!vault.isInitialized)
        #expect(!vault.isUnlocked)
        try vault.reset() // idempotent
        try vault.setup(masterPassword: "fresh")
        #expect(vault.isUnlocked)
    }

    @Test func pbkdf2KnownVector() throws {
        // RFC 7914 §11 PBKDF2-HMAC-SHA256 test vector ("passwd"/"salt", c=1), first 32 bytes.
        let key = try SiteVault.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }
}
