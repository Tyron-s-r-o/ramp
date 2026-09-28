import CommonCrypto
import CryptoKit
import Foundation
import Security
import Synchronization

/// Encrypted secret storage for saved sites, protected by a user master password
/// (FileZilla-style). File: `<root>/remote/vault.json` (0600, directory 0700).
///
/// ```
/// {"version":1,"kdf":"pbkdf2-sha256","iterations":600000,"salt":"<b64>",
///  "check":"<b64 AES.GCM combined of a constant marker>",
///  "secrets":{"<site UUID>":"<b64 AES.GCM combined JSON of SiteSecrets>"}}
/// ```
///
/// The derived 32-byte key is held in memory only while unlocked; plaintext secrets are never
/// written to disk or logged. Every seal uses a fresh random nonce.
public final class SiteVault: Sendable {
    public static let defaultIterations = 600_000

    public let url: URL
    private let iterations: Int
    private let state = Mutex(State())

    private struct State {
        var key: SymmetricKey?
        /// Last loaded / written file content (valid while unlocked).
        var file: VaultFile?
    }

    struct VaultFile: Codable, Equatable {
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var check: String
        var secrets: [String: String]
    }

    private static let checkMarker = Data("RAMP-SiteVault-v1".utf8)
    private static let saltLength = 16

    public init(url: URL, iterations: Int = SiteVault.defaultIterations) {
        self.url = url
        self.iterations = iterations
    }

    /// The vault file exists (a master password was set up).
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    public var isUnlocked: Bool {
        state.withLock { $0.key != nil }
    }

    /// First-time setup: creates an empty vault and leaves it unlocked.
    public func setup(masterPassword: String) throws {
        try Self.validate(masterPassword)
        guard !isInitialized else {
            throw RemoteError.protocolError("Trezor s prístupmi už existuje.")
        }
        let (file, key) = try Self.makeFile(password: masterPassword, iterations: iterations, secrets: [:])
        try state.withLock { s in
            try write(file)
            s.key = key
            s.file = file
        }
    }

    /// Wrong password → `RemoteError.wrongMasterPassword`.
    public func unlock(masterPassword: String) throws {
        let file = try readFile()
        let key = try Self.verifiedKey(password: masterPassword, file: file)
        state.withLock { s in
            s.key = key
            s.file = file
        }
    }

    public func lock() {
        state.withLock { s in
            s.key = nil
            s.file = nil
        }
    }

    /// Locked → `RemoteError.vaultLocked`; unknown site → nil.
    public func secrets(for id: UUID) throws -> SiteSecrets? {
        try state.withLock { s in
            let (key, file) = try Self.unlocked(s)
            guard let sealed = file.secrets[id.uuidString] else { return nil }
            let plain = try Self.open(sealed, key: key)
            return try JSONDecoder().decode(SiteSecrets.self, from: plain)
        }
    }

    public func setSecrets(_ secrets: SiteSecrets, for id: UUID) throws {
        try state.withLock { s in
            let (key, current) = try Self.unlocked(s)
            var file = current
            file.secrets[id.uuidString] = try Self.seal(JSONEncoder().encode(secrets), key: key)
            try write(file)
            s.file = file
        }
    }

    public func removeSecrets(for id: UUID) throws {
        try state.withLock { s in
            let (_, current) = try Self.unlocked(s)
            guard current.secrets[id.uuidString] != nil else { return }
            var file = current
            file.secrets[id.uuidString] = nil
            try write(file)
            s.file = file
        }
    }

    /// Verifies `old`, re-encrypts every secret under `new` with a fresh salt; vault stays unlocked.
    public func changeMasterPassword(old: String, new: String) throws {
        try Self.validate(new)
        let current = try readFile()
        let oldKey = try Self.verifiedKey(password: old, file: current)
        var plain: [String: Data] = [:]
        for (id, sealed) in current.secrets {
            plain[id] = try Self.open(sealed, key: oldKey)
        }
        let (file, key) = try Self.makeFile(password: new, iterations: iterations, secrets: plain)
        try state.withLock { s in
            try write(file)
            s.key = key
            s.file = file
        }
    }

    /// "Forgot password": deletes the vault file (all secrets are lost); locked, not initialized.
    public func reset() throws {
        try state.withLock { s in
            s.key = nil
            s.file = nil
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone.
            }
        }
    }

    // MARK: Private

    private func write(_ file: VaultFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.writeAtomically(encoder.encode(file), to: url)
    }

    private func readFile() throws -> VaultFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw RemoteError.protocolError("Trezor s prístupmi ešte nie je vytvorený.")
        }
        guard let file = try? JSONDecoder().decode(VaultFile.self, from: data),
              file.version == 1, file.kdf == "pbkdf2-sha256", file.iterations > 0 else {
            throw RemoteError.protocolError("Súbor trezora je poškodený (\(url.lastPathComponent)).")
        }
        return file
    }

    private static func unlocked(_ s: State) throws -> (SymmetricKey, VaultFile) {
        guard let key = s.key, let file = s.file else { throw RemoteError.vaultLocked }
        return (key, file)
    }

    private static func validate(_ password: String) throws {
        guard !password.isEmpty else {
            throw RemoteError.protocolError("Hlavné heslo nesmie byť prázdne.")
        }
    }

    private static func verifiedKey(password: String, file: VaultFile) throws -> SymmetricKey {
        guard !password.isEmpty, let salt = Data(base64Encoded: file.salt) else {
            throw RemoteError.wrongMasterPassword
        }
        let key = try deriveKey(password: password, salt: salt, iterations: file.iterations)
        guard let marker = try? open(file.check, key: key), marker == checkMarker else {
            throw RemoteError.wrongMasterPassword
        }
        return key
    }

    /// New file with a fresh salt; `secrets` are plaintext JSON blobs keyed by site UUID string.
    private static func makeFile(password: String, iterations: Int,
                                 secrets: [String: Data]) throws -> (VaultFile, SymmetricKey) {
        let salt = try randomBytes(saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        var sealed: [String: String] = [:]
        for (id, plain) in secrets {
            sealed[id] = try seal(plain, key: key)
        }
        let file = VaultFile(version: 1, kdf: "pbkdf2-sha256", iterations: iterations,
                             salt: salt.base64EncodedString(), check: try seal(checkMarker, key: key),
                             secrets: sealed)
        return (file, key)
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pw = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = pw.withUnsafeBufferPointer { pwBuf in
            salt.withUnsafeBytes { saltBuf in
                pwBuf.withMemoryRebound(to: CChar.self) { pwChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwChars.baseAddress, pwChars.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else {
            throw RemoteError.protocolError("Odvodenie kľúča trezora zlyhalo (\(status)).")
        }
        defer { derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: derived)
    }

    private static func seal(_ plain: Data, key: SymmetricKey) throws -> String {
        guard let combined = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce()).combined else {
            throw RemoteError.protocolError("Šifrovanie trezora zlyhalo.")
        }
        return combined.base64EncodedString()
    }

    private static func open(_ b64: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: b64) else {
            throw RemoteError.protocolError("Súbor trezora je poškodený.")
        }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw RemoteError.protocolError("Generovanie náhodných dát zlyhalo.")
        }
        return Data(bytes)
    }
}
