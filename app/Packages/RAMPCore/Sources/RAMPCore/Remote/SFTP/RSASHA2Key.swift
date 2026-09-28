import CCryptoBoringSSL
import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// RSA user authentication with SHA-2 signatures (RFC 8332: "rsa-sha2-512" / "rsa-sha2-256").
///
/// Citadel 0.12.1 only signs RSA with SHA-1 ("ssh-rsa"), which OpenSSH ≥ 8.8 rejects by default,
/// and neither Citadel nor its swift-nio-ssh fork know rsa-sha2-*. NIOSSH writes a custom key's
/// `publicKeyPrefix` both as the userauth *algorithm name* and as the *type inside the key blob*,
/// but RFC 8332 wants `rsa-sha2-512` + a blob typed `ssh-rsa`. So the public key below advertises
/// the SHA-2 name and, in `write(to:)`, rewrites the prefix NIOSSH has just put into the blob back
/// to `ssh-rsa`.
///
/// The key material comes from Citadel's parser (OpenSSH format, bcrypt + AES-CTR decryption);
/// its private exponent is internal, so it is read by reflection (`RSASHA2Error.unsupportedKey`
/// if a future Citadel renames it). These types are client-only and are never registered with
/// `NIOSSHAlgorithms` (that would also advertise the name as a host key algorithm).
enum RSASHA2 {
    /// Signature algorithms in preference order (plus Citadel's legacy "ssh-rsa" as a last resort).
    enum Algorithm: String, CaseIterable, Sendable {
        case sha512 = "rsa-sha2-512"
        case sha256 = "rsa-sha2-256"
    }

    static func privateKey(_ key: Insecure.RSA.PrivateKey, algorithm: Algorithm) throws -> NIOSSHPrivateKey {
        switch algorithm {
        case .sha512: NIOSSHPrivateKey(custom: try RSASHA2PrivateKey<RSASHA512>(key))
        case .sha256: NIOSSHPrivateKey(custom: try RSASHA2PrivateKey<RSASHA256>(key))
        }
    }

    /// One public-key offer; Citadel's `SSHAuthenticationMethod.custom` asks it exactly once.
    static func authentication(username: String, key: Insecure.RSA.PrivateKey, algorithm: Algorithm) throws -> SSHAuthenticationMethod {
        .custom(SingleKeyOffer(username: username, privateKey: try privateKey(key, algorithm: algorithm)))
    }
}

enum RSASHA2Error: Error {
    case unsupportedKey
    case signingFailed
}

// MARK: - Variants

protocol RSASHA2Variant {
    static var name: String { get }
    static var nid: Int32 { get }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8]
}

enum RSASHA512: RSASHA2Variant {
    static var name: String { RSASHA2.Algorithm.sha512.rawValue }
    static var nid: Int32 { NID_sha512 }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA512.hash(data: data)) }
}

enum RSASHA256: RSASHA2Variant {
    static var name: String { RSASHA2.Algorithm.sha256.rawValue }
    static var nid: Int32 { NID_sha256 }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

// MARK: - Keys

final class RSASHA2PublicKey<V: RSASHA2Variant>: NIOSSHPublicKeyProtocol, @unchecked Sendable {
    static var publicKeyPrefix: String { V.name }

    /// `mpint e || mpint n` — the `ssh-rsa` key blob without its type string.
    let rawRepresentation: Data

    init(rawRepresentation: Data) { self.rawRepresentation = rawRepresentation }

    /// Client-only type: the server verifies, we never do.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }

    /// NIOSSH has just written `string V.name` in front of us; turn it into `string "ssh-rsa"`.
    func write(to buffer: inout ByteBuffer) -> Int {
        let prefix = Array(V.name.utf8)
        let start = buffer.writerIndex - 4 - prefix.count
        guard start >= buffer.readerIndex,
              buffer.getInteger(at: start, as: UInt32.self) == UInt32(prefix.count),
              buffer.getBytes(at: start + 4, length: prefix.count) == prefix else {
            return buffer.writeBytes(rawRepresentation)
        }
        buffer.moveWriterIndex(to: start)
        let type = Array("ssh-rsa".utf8)
        var written = buffer.writeInteger(UInt32(type.count))
        written += buffer.writeBytes(type)
        written += buffer.writeBytes(rawRepresentation)
        return written - 4 - prefix.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA2PublicKey<V> {
        throw RSASHA2Error.unsupportedKey
    }
}

struct RSASHA2Signature<V: RSASHA2Variant>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { V.name }
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA2Signature<V> {
        guard let length = buffer.readInteger(as: UInt32.self), let bytes = buffer.readBytes(length: Int(length)) else {
            throw RSASHA2Error.signingFailed
        }
        return RSASHA2Signature(rawRepresentation: Data(bytes))
    }
}

final class RSASHA2PrivateKey<V: RSASHA2Variant>: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { V.name }

    private let rsa: OpaquePointer
    private let _publicKey: RSASHA2PublicKey<V>
    var publicKey: NIOSSHPublicKeyProtocol { _publicKey }

    init(_ key: Insecure.RSA.PrivateKey) throws {
        let blob = key.publicKey.rawRepresentation
        var buffer = ByteBuffer(bytes: blob)
        guard let e = Self.readMPInt(&buffer), let n = Self.readMPInt(&buffer),
              let exponent = Mirror(reflecting: key).children.first(where: { $0.label == "privateExponent" })?.value
                as? UnsafeMutablePointer<BIGNUM>,
              let rsa = CCryptoBoringSSL_RSA_new() else {
            throw RSASHA2Error.unsupportedKey
        }
        let bnN = CCryptoBoringSSL_BN_bin2bn(n, n.count, nil)
        let bnE = CCryptoBoringSSL_BN_bin2bn(e, e.count, nil)
        let bnD = CCryptoBoringSSL_BN_dup(exponent)
        guard let bnN, let bnE, let bnD, CCryptoBoringSSL_RSA_set0_key(rsa, bnN, bnE, bnD) == 1 else {
            CCryptoBoringSSL_BN_free(bnN); CCryptoBoringSSL_BN_free(bnE); CCryptoBoringSSL_BN_free(bnD)
            CCryptoBoringSSL_RSA_free(rsa)
            throw RSASHA2Error.unsupportedKey
        }
        self.rsa = rsa
        self._publicKey = RSASHA2PublicKey(rawRepresentation: blob)
    }

    deinit { CCryptoBoringSSL_RSA_free(rsa) }

    /// RSASSA-PKCS1-v1_5 over SHA-512 / SHA-256 (RFC 8332 §3).
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let digest = V.digest(data)
        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_RSA_size(rsa)))
        var outLength = UInt32(out.count)
        guard CCryptoBoringSSL_RSA_sign(V.nid, digest, digest.count, &out, &outLength, rsa) == 1 else {
            throw RSASHA2Error.signingFailed
        }
        return RSASHA2Signature<V>(rawRepresentation: Data(out.prefix(Int(outLength))))
    }

    private static func readMPInt(_ buffer: inout ByteBuffer) -> [UInt8]? {
        guard let length = buffer.readInteger(as: UInt32.self) else { return nil }
        return buffer.readBytes(length: Int(length))
    }
}

// MARK: - Auth delegate

private final class SingleKeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let privateKey: NIOSSHPrivateKey

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey))))
    }
}
