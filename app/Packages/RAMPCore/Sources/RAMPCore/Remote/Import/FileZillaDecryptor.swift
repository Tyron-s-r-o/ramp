import CommonCrypto
import CryptoKit
import Foundation

/// Decrypts FileZilla passwords stored as `<Pass encoding="crypt" pubkey="…">…</Pass>`
/// (FileZilla 3.26+ "Use a master password to protect passwords").
///
/// Scheme (libfilezilla `lib/encryption.cpp`, FileZilla `src/commonui/site.cpp`,
/// `src/commonui/xmlfunctions.cpp`, `src/interface/loginmanager.cpp`):
///
/// - `pubkey` attribute = base64 (standard alphabet, unpadded) of `X25519 pub (32) || salt (32)`
///   — `fz::public_key::to_base64(false)`.
/// - Master key — `fz::private_key::from_password(utf8(password), pub.salt_)`:
///   `k = PBKDF2-HMAC-SHA256(password, salt, 100_000 iterations (min_iterations), 32 bytes)`,
///   clamped `k[0] &= 248; k[31] &= 127; k[31] |= 64`. Correct password ⇔
///   `X25519(k, 9) == pub.key_` (`private_key::pubkey()`, check in `CLoginManager::AskDecryptor`).
/// - Ciphertext (`<Pass>` text) = unpadded base64 of
///   `ephemeral pub (32) || ephemeral salt (32) || AES-256-GCM ciphertext || tag (16)`
///   — `fz::encrypt(…, authenticated = true)`.
/// - `secret = X25519(k, ephemeral pub)` (`private_key::shared_secret`).
/// - `aes_key = SHA256(eph.salt || 0x00 || secret || eph.key || pub.key || pub.salt)`,
///   `iv = SHA256(eph.salt || 0x02 || …same…)[0..<12]` (GCM, no AAD).
///   Legacy (unauthenticated, pre-GCM builds): AES-256-CTR, counter block =
///   `SHA256(eph.salt || 0x01 || …)[0..<16]`, layout without tag — `do_unprotect` falls back to it
///   when GCM fails ("Compatibility with unauthenticated encryption").
/// - Plaintext = UTF-8 password right-padded with NULs to ≥ 16 bytes (`protect()` "Primitive length
///   hiding"); `do_unprotect` rejects < 16 bytes, strips the trailing NUL run, rejects non-NUL after it.
public struct FileZillaDecryptor: Sendable {
    static let keySize = 32
    static let saltSize = 32
    static let tagSize = 16
    static let ivSize = 12
    static let iterations: UInt32 = 100_000

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Data   // 32
    let salt: Data        // 32

    /// Derives the X25519 private key from `masterPassword` and the salt inside `pubkey`.
    /// Throws `RemoteError.wrongMasterPassword` when the derived public key ≠ the stored one.
    public init(masterPassword: String, pubkey: String) throws {
        guard let raw = Self.base64(pubkey), raw.count == Self.keySize + Self.saltSize else {
            throw RemoteError.protocolError("FileZilla: neplatný verejný kľúč (pubkey).")
        }
        let storedKey = raw.prefix(Self.keySize)
        let salt = raw.suffix(Self.saltSize)
        // libfilezilla returns an invalid key for an empty password → it can never match.
        guard !masterPassword.isEmpty,
              let key = Self.derivePrivateKey(password: Data(masterPassword.utf8), salt: Data(salt)),
              key.publicKey.rawRepresentation == storedKey else {
            throw RemoteError.wrongMasterPassword
        }
        self.privateKey = key
        self.publicKey = Data(storedKey)
        self.salt = Data(salt)
    }

    /// Decrypts one `<Pass encoding="crypt">` value into the plain password.
    public func decrypt(_ base64Cipher: String) throws -> String {
        guard let cipher = Self.base64(base64Cipher), cipher.count >= Self.keySize + Self.saltSize else {
            throw Self.failure
        }
        let ephKey = cipher.prefix(Self.keySize)
        let ephSalt = cipher.dropFirst(Self.keySize).prefix(Self.saltSize)
        let body = cipher.dropFirst(Self.keySize + Self.saltSize)

        guard let ephPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephKey),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: ephPub) else {
            throw Self.failure
        }
        let secret = shared.withUnsafeBytes { Data($0) }

        let aesKey = SymmetricKey(data: Self.kdf(ephSalt, 0, secret, ephKey, publicKey, salt))
        var plain: Data?
        if body.count >= Self.tagSize {
            let iv = Self.kdf(ephSalt, 2, secret, ephKey, publicKey, salt).prefix(Self.ivSize)
            if let nonce = try? AES.GCM.Nonce(data: iv),
               let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(Self.tagSize),
                                                tag: body.suffix(Self.tagSize)) {
                plain = try? AES.GCM.open(box, using: aesKey)
            }
        }
        if plain == nil {
            // site.cpp do_unprotect: "Compatibility with unauthenticated encryption, remove eventually."
            let ctr = Self.kdf(ephSalt, 1, secret, ephKey, publicKey, salt).prefix(16)
            plain = Self.aesCTR(key: aesKey, counter: Data(ctr), input: Data(body))
        }
        guard let plain else { throw Self.failure }
        return try Self.unpad(plain)
    }

    // MARK: Internals (shared with the test-only encryptor)

    static let failure = RemoteError.protocolError("FileZilla: heslo sa nepodarilo dešifrovať.")

    /// Tolerates FileZilla's unpadded base64 and stray whitespace.
    static func base64(_ string: String) -> Data? {
        var s = string.filter { !$0.isWhitespace }
        if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
        return Data(base64Encoded: s)
    }

    /// `private_key::from_password`: PBKDF2-HMAC-SHA256 → clamp.
    static func derivePrivateKey(password: Data, salt: Data, iterations: UInt32 = iterations)
        -> Curve25519.KeyAgreement.PrivateKey? {
        var key = [UInt8](repeating: 0, count: keySize)
        let status = password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                     s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &key, key.count)
            }
        }
        guard status == kCCSuccess else { return nil }
        key[0] &= 248
        key[31] &= 127
        key[31] |= 64
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: key)
    }

    /// `hash_accumulator(sha256) << eph.salt_ << tag << secret << eph.key_ << pub.key_ << pub.salt_`
    /// (`<< 0` hits `hash_accumulator::update(uint8_t)` → a single byte).
    static func kdf(_ ephSalt: some DataProtocol, _ tag: UInt8, _ secret: Data,
                    _ ephKey: some DataProtocol, _ pubKey: Data, _ pubSalt: Data) -> Data {
        var h = SHA256()
        h.update(data: Data(ephSalt))
        h.update(data: Data([tag]))
        h.update(data: secret)
        h.update(data: Data(ephKey))
        h.update(data: pubKey)
        h.update(data: pubSalt)
        return Data(h.finalize())
    }

    /// AES-256-CTR, 128-bit big-endian counter (nettle `ctr_crypt` with block size 16).
    static func aesCTR(key: SymmetricKey, counter: Data, input: Data) -> Data? {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        var cryptor: CCCryptorRef?
        let created = keyBytes.withUnsafeBytes { k in
            counter.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), iv.baseAddress, k.baseAddress, k.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { i in
            CCCryptorUpdate(cryptor, i.baseAddress, i.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess, moved == input.count else { return nil }
        return Data(out)
    }

    /// `do_unprotect` length-hiding removal.
    static func unpad(_ plain: Data) throws -> String {
        guard plain.count >= 16 else { throw failure }
        var bytes = [UInt8](plain)
        if let nul = bytes.firstIndex(of: 0) {
            guard bytes[nul...].allSatisfy({ $0 == 0 }) else { throw failure }
            bytes = Array(bytes[..<nul])
        }
        guard let pw = String(bytes: bytes, encoding: .utf8) else { throw failure }
        return pw
    }
}
