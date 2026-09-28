import Foundation

/// Reads FileZilla's Site Manager export (`sitemanager.xml`) into `RemoteSite` + `SiteSecrets`.
///
/// - `<Folder>` nesting → `group` ("Clients / Shop"); servers at the top level have no group.
/// - `<Protocol>`: 0 FTP (FileZilla's "explicit TLS if available") → `.ftpes`, 1 → `.sftp`,
///   3 → `.ftps` (implicit), 4 → `.ftpes`, 6 (insecure plain FTP) → `.ftp`; others are skipped.
/// - `<Pass encoding="base64">` decoded, plain `<Pass>` as is, `encoding="crypt"` (encrypted with the
///   FileZilla master password) → no password yet, `.encryptedWithMasterPassword` + `encryptedPassword`;
///   `decryptPasswords(_:masterPassword:)` unlocks them.
public enum FileZillaImporter {
    public enum PasswordStatus: String, Sendable, Hashable {
        case imported
        case encryptedWithMasterPassword
        case none
    }

    public struct Entry: Sendable, Hashable {
        public var site: RemoteSite
        public var secrets: SiteSecrets?
        public var passwordStatus: PasswordStatus
        /// Raw `<Pass encoding="crypt">` payload, kept so `decryptPasswords` can unlock it later.
        public var encryptedPassword: EncryptedPassword? = nil
    }

    /// FileZilla master-password protected password (see `FileZillaDecryptor`).
    public struct EncryptedPassword: Sendable, Hashable {
        public var cipher: String
        public var pubkey: String
        public init(cipher: String, pubkey: String) {
            self.cipher = cipher
            self.pubkey = pubkey
        }
    }

    /// `~/.config/filezilla/sitemanager.xml`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/filezilla/sitemanager.xml", directoryHint: .notDirectory)
    }

    public static func load(from url: URL = defaultURL) throws -> [Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RemoteError.notFound(url.path(percentEncoded: false))
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [])
        } catch {
            throw RemoteError.protocolError("Súbor FileZilla sa nedá prečítať: \(error.localizedDescription)")
        }
        guard let root = doc.rootElement() else { return [] }
        let servers = root.elements(forName: "Servers")
        // Some exports (single-site export) put <Servers> at the root; be lenient.
        let containers = servers.isEmpty ? [root] : servers
        var entries: [Entry] = []
        for container in containers {
            walk(container, folders: [], into: &entries)
        }
        return entries
    }

    /// Decrypts every `.encryptedWithMasterPassword` entry with the FileZilla master password.
    ///
    /// The password is verified against every distinct `pubkey` first (FileZilla uses one per master
    /// password), so a wrong password throws `RemoteError.wrongMasterPassword` before anything is
    /// decrypted. Entries encrypted with a different pubkey than the first match can't occur in one
    /// FileZilla profile; if they do, the whole call fails as wrong password. A single entry whose
    /// ciphertext is corrupt stays `.encryptedWithMasterPassword` (no secret) instead of failing all.
    public static func decryptPasswords(_ entries: [Entry], masterPassword: String) throws -> [Entry] {
        var decryptors: [String: FileZillaDecryptor] = [:]
        for pubkey in Set(entries.compactMap { $0.passwordStatus == .encryptedWithMasterPassword ? $0.encryptedPassword?.pubkey : nil }) {
            decryptors[pubkey] = try FileZillaDecryptor(masterPassword: masterPassword, pubkey: pubkey)
        }
        return entries.map { entry in
            guard entry.passwordStatus == .encryptedWithMasterPassword, let enc = entry.encryptedPassword,
                  let decryptor = decryptors[enc.pubkey],
                  let password = try? decryptor.decrypt(enc.cipher) else { return entry }
            var out = entry
            var secrets = out.secrets ?? SiteSecrets()
            secrets.password = password
            out.secrets = secrets
            out.passwordStatus = .imported
            out.encryptedPassword = nil
            return out
        }
    }

    // MARK: Private

    private static func walk(_ element: XMLElement, folders: [String], into entries: inout [Entry]) {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            switch el.name {
            case "Folder":
                let name = folderName(el)
                walk(el, folders: name.isEmpty ? folders : folders + [name], into: &entries)
            case "Server":
                if let entry = server(el, folders: folders) { entries.append(entry) }
            default:
                continue
            }
        }
    }

    /// Folder name = its own text node(s), not the text of nested servers.
    private static func folderName(_ el: XMLElement) -> String {
        (el.children ?? []).filter { $0.kind == .text }
            .compactMap(\.stringValue).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ el: XMLElement, _ name: String) -> String? {
        guard let value = el.elements(forName: name).first?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func mapProtocol(_ value: Int) -> RemoteProtocol? {
        switch value {
        // 0 = FileZilla's default "Use explicit FTP over TLS if available": TLS is optional there and most such
        // sites are plain FTP in practice — importing them as FTPES (TLS required) made them all fail.
        case 0: .ftp
        case 4: .ftpes
        case 1: .sftp
        case 3: .ftps
        case 6: .ftp
        default: nil
        }
    }

    private static func server(_ el: XMLElement, folders: [String]) -> Entry? {
        guard let host = text(el, "Host"),
              let proto = mapProtocol(Int(text(el, "Protocol") ?? "0") ?? -1) else { return nil }
        let port = Int(text(el, "Port") ?? "").flatMap { $0 > 0 && $0 < 65536 ? $0 : nil }
        // Older FileZilla versions stored the site name as the server's own trailing text.
        let ownText = (el.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = text(el, "Name") ?? (ownText.isEmpty ? host : ownText)
        let keyfile = proto == .sftp ? text(el, "Keyfile") : nil
        let passive = text(el, "PasvMode") != "MODE_ACTIVE"
        let site = RemoteSite(
            name: name, proto: proto, host: host, port: port, username: text(el, "User") ?? "",
            auth: keyfile != nil ? .privateKey : .password, privateKeyPath: keyfile,
            initialPath: text(el, "RemoteDir").flatMap(decodeRemoteDir), passive: passive,
            group: folders.isEmpty ? nil : folders.joined(separator: " / "),
            notes: el.elements(forName: "Comments").first?.stringValue.flatMap { $0.isEmpty ? nil : $0 })

        var status = PasswordStatus.none
        var secrets: SiteSecrets?
        var encrypted: EncryptedPassword?
        if let pass = el.elements(forName: "Pass").first, let raw = pass.stringValue, !raw.isEmpty {
            switch pass.attribute(forName: "encoding")?.stringValue?.lowercased() {
            case "crypt":
                status = .encryptedWithMasterPassword
                if let pubkey = pass.attribute(forName: "pubkey")?.stringValue, !pubkey.isEmpty {
                    encrypted = EncryptedPassword(cipher: raw.filter { !$0.isWhitespace }, pubkey: pubkey)
                }
            case "base64":
                let compact = raw.filter { !$0.isWhitespace }
                if let data = Data(base64Encoded: compact), let pw = String(data: data, encoding: .utf8), !pw.isEmpty {
                    secrets = SiteSecrets(password: pw)
                    status = .imported
                }
            case nil, "plain", "":
                secrets = SiteSecrets(password: raw)
                status = .imported
            default:
                break
            }
        }
        return Entry(site: site, secrets: secrets, passwordStatus: status, encryptedPassword: encrypted)
    }

    /// FileZilla's server path encoding: `<type> <prefixLen> [<prefix>] (<len> <segment>)*`,
    /// e.g. `"1 0 3 var 3 www"` → `"/var/www"`. Segments are length-prefixed (may contain spaces).
    /// Returns nil for empty / unparsable values.
    static func decodeRemoteDir(_ encoded: String) -> String? {
        let chars = Array(encoded)
        var i = 0

        func readInt() -> Int? {
            while i < chars.count, chars[i] == " " { i += 1 }
            var digits = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            return Int(digits)
        }
        func readString(_ length: Int) -> String? {
            guard i < chars.count, chars[i] == " " else { return nil }
            i += 1
            guard i + length <= chars.count else { return nil }
            defer { i += length }
            return String(chars[i..<i + length])
        }

        guard readInt() != nil, let prefixLen = readInt() else { return nil }
        var prefix = ""
        if prefixLen > 0 {
            guard let p = readString(prefixLen) else { return nil }
            prefix = p
        }
        var segments: [String] = []
        while i < chars.count {
            guard let len = readInt() else { return nil }
            guard let segment = readString(len) else { return nil }
            segments.append(segment)
        }
        let path = "/" + segments.joined(separator: "/")
        return prefix.isEmpty ? path : prefix + path
    }
}
