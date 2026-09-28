import Citadel
import Crypto
import Foundation

/// Turns the site's private key file into Citadel authentication methods, in the order to try them
/// (one connection attempt each). ed25519 → one method; RSA → rsa-sha2-512, rsa-sha2-256
/// (RFC 8332, see `RSASHA2`) and legacy SHA-1 "ssh-rsa" for very old servers.
/// Supported: OpenSSH-format (`BEGIN OPENSSH PRIVATE KEY`) ed25519 and RSA, unencrypted or
/// encrypted with bcrypt + aes128/256-ctr (the `ssh-keygen` default). Anything else gets a clear
/// `RemoteError` telling the user how to convert the key.
enum SFTPKeyLoader {
    static func authentications(username: String, keyPath: String, passphrase: String?) throws -> [SSHAuthenticationMethod] {
        let url = URL(filePath: (keyPath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw RemoteError.protocolError("Súbor s kľúčom sa nedá prečítať: \(keyPath)")
        }
        let header = OpenSSHKeyHeader(text)
        guard let header else {
            if text.contains("BEGIN RSA PRIVATE KEY") || text.contains("BEGIN EC PRIVATE KEY")
                || text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
                throw RemoteError.protocolError(
                    "Kľúč je v starom PEM formáte. Preveď ho do OpenSSH formátu: ssh-keygen -p -o -f \(keyPath)")
            }
            if text.contains("PuTTY-User-Key-File") {
                throw RemoteError.protocolError(
                    "Kľúč je vo formáte PuTTY (.ppk). Exportuj ho v PuTTYgen ako OpenSSH kľúč.")
            }
            throw RemoteError.protocolError("Nepodporovaný formát kľúča: \(keyPath)")
        }
        if header.encrypted, (passphrase ?? "").isEmpty { throw RemoteError.missingSecret }
        guard header.cipher == "none" || header.cipher == "aes256-ctr" || header.cipher == "aes128-ctr" else {
            throw RemoteError.protocolError(
                "Kľúč je zašifrovaný nepodporovanou šifrou (\(header.cipher)). Zmeň passphrase: ssh-keygen -p -Z aes256-ctr -f \(keyPath)")
        }
        let decryptionKey = header.encrypted ? passphrase.map { Data($0.utf8) } : nil

        do {
            switch header.keyType {
            case "ssh-ed25519":
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey)
                return [.ed25519(username: username, privateKey: key)]
            case "ssh-rsa":
                let key = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey)
                let sha2 = try RSASHA2.Algorithm.allCases.map {
                    try RSASHA2.authentication(username: username, key: key, algorithm: $0)
                }
                return sha2 + [.rsa(username: username, privateKey: key)]
            default:
                throw RemoteError.protocolError(
                    "Typ kľúča \(header.keyType) nie je podporovaný (podporované: ed25519, RSA).")
            }
        } catch let error as RemoteError {
            throw error
        } catch let error as RSASHA2Error {
            throw RemoteError.protocolError("RSA kľúč sa nepodarilo pripraviť na podpis SHA-2 (\(error)).")
        } catch {
            if header.encrypted {
                throw RemoteError.protocolError("Nesprávna passphrase ku kľúču \(keyPath).")
            }
            throw RemoteError.protocolError("Kľúč sa nepodarilo načítať (\(error)).")
        }
    }
}

/// The unencrypted header of an `openssh-key-v1` blob: cipher, kdf and the public key type.
struct OpenSSHKeyHeader {
    let cipher: String
    let kdf: String
    let keyType: String
    var encrypted: Bool { cipher != "none" }

    init?(_ pem: String) {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end, range: b.upperBound..<pem.endIndex) else { return nil }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { return nil }
        var r = Reader(bytes: [UInt8](data))
        guard r.take(15) == Array("openssh-key-v1\0".utf8),
              let cipher = r.string(), let kdf = r.string(), r.blob() != nil,
              let count = r.uint32(), count == 1, let pub = r.blob() else { return nil }
        var pr = Reader(bytes: pub)
        guard let type = pr.string() else { return nil }
        self.cipher = cipher
        self.kdf = kdf
        self.keyType = type
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, pos + n <= bytes.count else { return nil }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }
        mutating func uint32() -> UInt32? {
            take(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }
        mutating func blob() -> [UInt8]? {
            uint32().flatMap { take(Int($0)) }
        }
        mutating func string() -> String? {
            blob().flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }
}
