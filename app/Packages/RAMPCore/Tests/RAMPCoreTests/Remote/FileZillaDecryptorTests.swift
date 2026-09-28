import CryptoKit
import Foundation
import Testing
@testable import RAMPCore

/// Test-only mirror of libfilezilla `fz::encrypt(plain, pub, authenticated)` (lib/encryption.cpp)
/// + FileZilla `protect()` NUL padding (src/commonui/site.cpp).
enum FileZillaTestEncryptor {
    /// `private_key::from_password(pw, salt).pubkey().to_base64(false)`.
    static func pubkey(masterPassword: String, salt: Data) -> String {
        let priv = FileZillaDecryptor.derivePrivateKey(password: Data(masterPassword.utf8), salt: salt)!
        return b64(priv.publicKey.rawRepresentation + salt)
    }

    static func encrypt(_ password: String, pubkey: String, authenticated: Bool = true) -> String {
        let raw = FileZillaDecryptor.base64(pubkey)!
        let pubKey = Data(raw.prefix(32)), pubSalt = Data(raw.suffix(32))
        var plain = Data(password.utf8)
        if plain.count < 16 { plain.append(Data(count: 16 - plain.count)) }

        // private_key::generate(): random clamped key + random salt.
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephKey = eph.publicKey.rawRepresentation
        let ephSalt = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let secret = try! eph.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: pubKey)).withUnsafeBytes { Data($0) }

        let key = SymmetricKey(data: FileZillaDecryptor.kdf(ephSalt, 0, secret, ephKey, pubKey, pubSalt))
        let body: Data
        if authenticated {
            let iv = FileZillaDecryptor.kdf(ephSalt, 2, secret, ephKey, pubKey, pubSalt).prefix(12)
            let box = try! AES.GCM.seal(plain, using: key, nonce: .init(data: iv))
            body = box.ciphertext + box.tag
        } else {
            let ctr = FileZillaDecryptor.kdf(ephSalt, 1, secret, ephKey, pubKey, pubSalt).prefix(16)
            body = FileZillaDecryptor.aesCTR(key: key, counter: Data(ctr), input: plain)!
        }
        return b64(ephKey + ephSalt + body)
    }

    static func b64(_ d: Data) -> String {
        var s = d.base64EncodedString()
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}

@Suite struct FileZillaDecryptorTests {
    static let master = "master heslo ľšč"
    static let salt = Data((0..<32).map { UInt8($0) })

    // Independent reference vectors produced with Python `cryptography` + hashlib, following
    // libfilezilla lib/encryption.cpp (password + salt above; fixed ephemeral keys).
    static let refPubkey = "zdcaYObsbdn1NYjTLjkp8tx2x4y/pZLG8EPWiY1eFDYAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHw"
    static let refShort = "Gr2DdjCVB3K29/gLmr0lGvFoMSHzShBoRu5/mGwE6Bs4Wj1wRwXPFeRKd3+0nDjGswbgvM08/5PVwaP0FMcrpuewPctue0DBxFERrZB6uMp8ODHUZL7LMtz0mLAlR/9u"
    static let refLong = "d/p/rxssn4ZHF/ZiaNx9Wr2jRqBS5KT3dxVzDHqqyh3CJUpzLySxf5K6UHS0iSltEsmr6bnaO7ClRNNetpYRTPyy07s3qZfQwpLUqlPK71v3gZf4aZsPjbJMA3GZTk3TU5Z9qyqIefnwFCu3De+QYvERzWrku8lrW3J4AE2015sJD47H"
    static let refLegacyCTR = "WZpyd/N73PSz9ANnnv9gyd7MGi6sUmM6QTAta6qgjl8F5OQCwdZWHYO8pM6dfrt8xoGZg0u8umTK6jhJ+kYHkfj2Qr2dkG8ua1uX9mSrZCg"

    @Test func derivedPubkeyMatchesReference() {
        #expect(FileZillaTestEncryptor.pubkey(masterPassword: Self.master, salt: Self.salt) == Self.refPubkey)
    }

    @Test func decryptsReferenceVectors() throws {
        let d = try FileZillaDecryptor(masterPassword: Self.master, pubkey: Self.refPubkey)
        #expect(try d.decrypt(Self.refShort) == "pass word šč")
        #expect(try d.decrypt(Self.refLong) == String(repeating: "a", count: 40) + "-dlhé heslo")
        #expect(try d.decrypt(Self.refLegacyCTR) == "legacy-pw")
    }

    @Test func wrongPasswordThrows() {
        #expect(throws: RemoteError.wrongMasterPassword) {
            try FileZillaDecryptor(masterPassword: "zle", pubkey: Self.refPubkey)
        }
        #expect(throws: RemoteError.wrongMasterPassword) {
            try FileZillaDecryptor(masterPassword: "", pubkey: Self.refPubkey)
        }
    }

    @Test func roundTrip() throws {
        let d = try FileZillaDecryptor(masterPassword: Self.master, pubkey: Self.refPubkey)
        for pw in ["", "x", "exactly16bytes!!", "p@ss w0rd ľščťžýáíé 🔑", String(repeating: "z", count: 200)] {
            #expect(try d.decrypt(FileZillaTestEncryptor.encrypt(pw, pubkey: Self.refPubkey)) == pw)
            #expect(try d.decrypt(FileZillaTestEncryptor.encrypt(pw, pubkey: Self.refPubkey, authenticated: false)) == pw)
        }
    }

    @Test func layoutLengths() throws {
        let c = FileZillaDecryptor.base64(FileZillaTestEncryptor.encrypt("short", pubkey: Self.refPubkey))!
        #expect(c.count == 32 + 32 + 16 + 16)   // eph pub + eph salt + padded plaintext + GCM tag
    }

    @Test func tamperedCipherFails() throws {
        let d = try FileZillaDecryptor(masterPassword: Self.master, pubkey: Self.refPubkey)
        var raw = FileZillaDecryptor.base64(Self.refShort)!
        raw[70] ^= 0x01
        // GCM fails → legacy CTR fallback yields garbage that must not be accepted silently as valid
        // UTF-8 + NUL padding in practice; either throw or return something ≠ original.
        let result = try? d.decrypt(FileZillaTestEncryptor.b64(raw))
        #expect(result != "pass word šč")
        #expect(throws: (any Error).self) { try d.decrypt("AAAA") }
    }

    @Test func importerDecryptsEntries() throws {
        let pub = Self.refPubkey
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FileZilla3 version="3.71.1" platform="macos"><Servers>
          <Server><Host>a.example.com</Host><Protocol>0</Protocol><User>ua</User>
            <Pass encoding="crypt" pubkey="\(pub)">\(FileZillaTestEncryptor.encrypt("heslo-A", pubkey: pub))</Pass><Name>A</Name></Server>
          <Server><Host>b.example.com</Host><Protocol>1</Protocol><User>ub</User>
            <Pass encoding="crypt" pubkey="\(pub)">\(FileZillaTestEncryptor.encrypt("heslo-B ľš", pubkey: pub))</Pass><Name>B</Name></Server>
          <Server><Host>c.example.com</Host><Protocol>0</Protocol><User>uc</User>
            <Pass encoding="base64">cGxhaW4=</Pass><Name>C</Name></Server>
        </Servers></FileZilla3>
        """
        let entries = try FileZillaImporter.parse(Data(xml.utf8))
        #expect(entries.map(\.passwordStatus) == [.encryptedWithMasterPassword, .encryptedWithMasterPassword, .imported])
        #expect(entries[0].encryptedPassword?.pubkey == pub)
        #expect(entries[0].secrets == nil)

        #expect(throws: RemoteError.wrongMasterPassword) {
            try FileZillaImporter.decryptPasswords(entries, masterPassword: "zle")
        }

        let out = try FileZillaImporter.decryptPasswords(entries, masterPassword: Self.master)
        #expect(out.map(\.passwordStatus) == [.imported, .imported, .imported])
        #expect(out.map { $0.secrets?.password } == ["heslo-A", "heslo-B ľš", "plain"])
        #expect(out.allSatisfy { $0.encryptedPassword == nil })
        #expect(out.map(\.site) == entries.map(\.site))
    }

    /// Structural check of the user's real FileZilla file (skipped when absent).
    /// Prints/asserts counts and lengths only — never hosts, users or ciphertexts.
    @Test func realSitemanagerIsStructurallyConsistent() throws {
        let url = FileZillaImporter.defaultURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let encrypted = try FileZillaImporter.load(from: url).compactMap(\.encryptedPassword)
        guard !encrypted.isEmpty else { return }
        let pubkeys = Set(encrypted.map(\.pubkey))
        #expect(pubkeys.count == 1)
        #expect(pubkeys.allSatisfy { FileZillaDecryptor.base64($0)?.count == 64 })
        let lengths = encrypted.map { FileZillaDecryptor.base64($0.cipher)?.count ?? -1 }
        // eph pub 32 + eph salt 32 + ≥16 padded plaintext + 16 GCM tag.
        #expect(lengths.allSatisfy { $0 >= 96 })
        print("FileZilla real file: \(encrypted.count) crypt entries, \(pubkeys.count) pubkey, cipher bytes \(lengths.min()!)–\(lengths.max()!)")
    }
}
