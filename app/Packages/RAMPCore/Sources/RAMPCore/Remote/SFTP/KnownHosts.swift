import CryptoKit
import Foundation
import Synchronization

/// Trusted SFTP host keys, `<root>/remote/known_hosts.json` (0600, written atomically).
/// Maps `host:port` → OpenSSH-style fingerprint `SHA256:<base64 without padding>`.
/// Independent of `~/.ssh/known_hosts` — RAMP never writes the user's SSH files.
public final class KnownHosts: Sendable {
    public let fileURL: URL
    private let entries: Mutex<[String: String]>

    /// Loads the file if it exists (a missing or unreadable file means "nothing trusted yet").
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(FileFormat.self, from: $0) }
        entries = Mutex(loaded?.hosts ?? [:])
    }

    public func fingerprint(host: String, port: Int) -> String? {
        entries.withLock { $0[Self.key(host, port)] }
    }

    /// Remembers (or replaces) the fingerprint and persists the file.
    public func trust(host: String, port: Int, fingerprint: String) throws {
        try entries.withLock { hosts in
            var next = hosts
            next[Self.key(host, port)] = fingerprint
            try persist(next)
            hosts = next
        }
    }

    public func forget(host: String, port: Int) throws {
        try entries.withLock { hosts in
            var next = hosts
            guard next.removeValue(forKey: Self.key(host, port)) != nil else { return }
            try persist(next)
            hosts = next
        }
    }

    /// All entries (for a settings screen), keyed `host:port`.
    public var all: [String: String] { entries.withLock { $0 } }

    // MARK: Fingerprints

    /// OpenSSH `ssh-keygen -l` style: `SHA256:` + base64 (no padding) of SHA-256 over the key blob.
    public static func fingerprint(publicKeyBlob: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Same for an `authorized_keys`-style line (`ssh-ed25519 AAAA… comment`).
    public static func fingerprint(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return fingerprint(publicKeyBlob: blob)
    }

    // MARK: Private

    private struct FileFormat: Codable {
        var version = 1
        var hosts: [String: String]
    }

    static func key(_ host: String, _ port: Int) -> String {
        let h = host.lowercased()
        return h.contains(":") ? "[\(h)]:\(port)" : "\(h):\(port)"
    }

    private func persist(_ hosts: [String: String]) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(FileFormat(hosts: hosts))
        // Write a 0600 temp file next to the target, then rename over it (atomic).
        let tmp = dir.appending(path: ".known_hosts.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path(percentEncoded: false), contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path(percentEncoded: false)])
        }
        if rename(tmp.path(percentEncoded: false), fileURL.path(percentEncoded: false)) != 0 {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
