import Foundation

// Phase 9 — FTP/SFTP manager. Shared contract between the vault/store (09-01), the protocol
// clients (09-02) and the GUI (09-03). Keep this file small and stable; implementations live
// next to it (Remote/Vault, Remote/FTP, Remote/SFTP, Remote/Transfers).

/// Wire protocol of a saved site.
public enum RemoteProtocol: String, Codable, Sendable, CaseIterable, Hashable {
    /// Plain FTP (credentials in clear text — the editor warns).
    case ftp
    /// FTP with explicit TLS (AUTH TLS on port 21) — the common "FTPES" setup at Slovak hosts.
    case ftpes
    /// FTP over implicit TLS (port 990).
    case ftps
    /// SSH File Transfer Protocol (port 22).
    case sftp

    public var defaultPort: Int {
        switch self {
        case .ftp, .ftpes: 21
        case .ftps: 990
        case .sftp: 22
        }
    }
}

/// How the site authenticates. Secrets are never stored here — only a reference; the actual
/// password / key passphrase lives encrypted in the vault (`SiteSecrets`).
public enum RemoteAuthKind: String, Codable, Sendable, Hashable {
    case password
    /// SFTP only: private key file on disk (OpenSSH format), optional passphrase in the vault.
    case privateKey
}

/// A saved connection. Metadata is stored in plain JSON so the site list is visible without the
/// master password; secrets are separate and encrypted (see `SiteSecrets`).
public struct RemoteSite: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var proto: RemoteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var auth: RemoteAuthKind
    /// Absolute path of the private key file (auth == .privateKey).
    public var privateKeyPath: String?
    /// Folder opened after connecting ("" / nil = server default / home).
    public var initialPath: String?
    /// FTP/FTPS: passive mode (default true). Ignored for SFTP.
    public var passive: Bool
    /// FTPS: accept a certificate that fails system trust (self-signed hosting certs). Default false.
    public var allowInsecureCertificate: Bool
    /// Optional grouping in the list (same idea as vhost groups).
    public var group: String?
    public var notes: String?

    public init(id: UUID = UUID(), name: String, proto: RemoteProtocol, host: String,
                port: Int? = nil, username: String, auth: RemoteAuthKind = .password,
                privateKeyPath: String? = nil, initialPath: String? = nil, passive: Bool = true,
                allowInsecureCertificate: Bool = false, group: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.username = username
        self.auth = auth
        self.privateKeyPath = privateKeyPath
        self.initialPath = initialPath
        self.passive = passive
        self.allowInsecureCertificate = allowInsecureCertificate
        self.group = group
        self.notes = notes
    }
}

/// Decrypted secrets of one site (held in memory only while the vault is unlocked).
public struct SiteSecrets: Codable, Sendable, Hashable {
    public var password: String?
    public var keyPassphrase: String?
    public init(password: String? = nil, keyPassphrase: String? = nil) {
        self.password = password
        self.keyPassphrase = keyPassphrase
    }
}

/// One entry of a remote directory listing.
public struct RemoteItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case file, directory, symlink }

    /// Absolute remote path (POSIX, no trailing slash except "/").
    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64?
    public var modified: Date?
    /// e.g. "rwxr-xr-x" when the server reports it.
    public var permissions: String?

    public var id: String { path }

    public init(path: String, name: String, kind: Kind, size: Int64? = nil, modified: Date? = nil,
                permissions: String? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// Progress callback: bytes done / total (total nil when unknown). Called from any thread.
public typealias RemoteProgress = @Sendable (_ done: Int64, _ total: Int64?) -> Void

/// A connected session to one site. Implementations: `SFTPFileSystem` (Citadel), `FTPFileSystem`
/// (libcurl). All paths are absolute POSIX paths. Every call must honour Task cancellation
/// (abort the transfer, throw CancellationError) and must not block the caller's executor.
public protocol RemoteFileSystem: Sendable {
    /// Directory the session starts in (initialPath, else the server's home / cwd).
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [RemoteItem]
    func stat(_ path: String) async throws -> RemoteItem?
    /// Downloads one file to `localURL` (overwrites).
    func download(_ remotePath: String, to localURL: URL, progress: RemoteProgress?) async throws
    /// Uploads one file to `remotePath` (overwrites).
    func upload(_ localURL: URL, to remotePath: String, progress: RemoteProgress?) async throws
    func createDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    /// Deletes a file or an EMPTY directory (recursion is done by `TransferEngine` / callers).
    func delete(_ item: RemoteItem) async throws
    func close() async
}

public enum RemoteError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case wrongMasterPassword
    case missingSecret
    case connectionFailed(String)
    case authenticationFailed
    /// SFTP host key seen for the first time — the GUI must ask and call `KnownHosts.trust`.
    case unknownHostKey(host: String, port: Int, fingerprint: String)
    /// SFTP host key differs from the remembered one (possible MITM).
    case hostKeyMismatch(host: String, port: Int, expected: String, actual: String)
    case certificateUntrusted(String)
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .vaultLocked: "Trezor s prístupmi je zamknutý."
        case .wrongMasterPassword: "Nesprávne hlavné heslo."
        case .missingSecret: "Pre tento prístup nie je uložené heslo."
        case .connectionFailed(let m): "Nepodarilo sa pripojiť: \(m)"
        case .authenticationFailed: "Prihlásenie zlyhalo (meno, heslo alebo kľúč)."
        case .unknownHostKey(let h, _, let f): "Neznámy kľúč servera \(h): \(f)"
        case .hostKeyMismatch(let h, _, _, _): "Kľúč servera \(h) sa zmenil — pripojenie zastavené."
        case .certificateUntrusted(let m): "Certifikát servera nie je dôveryhodný: \(m)"
        case .notFound(let p): "Neexistuje: \(p)"
        case .permissionDenied(let p): "Prístup zamietnutý: \(p)"
        case .alreadyExists(let p): "Už existuje: \(p)"
        case .protocolError(let m): m
        }
    }
}

/// POSIX path helpers for remote paths.
public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
    }
    public static func parent(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
        let p = String(path[..<slash])
        return p.isEmpty ? "/" : p
    }
    public static func name(_ path: String) -> String {
        path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
    }
}
