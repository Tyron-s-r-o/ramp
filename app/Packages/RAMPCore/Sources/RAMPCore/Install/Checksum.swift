import CryptoKit
import Foundation

/// Streaming file hashes (1 MiB chunks — package tarballs are never loaded into memory whole).
public enum Checksum {
    static let chunkSize = 1 << 20

    /// Lowercase hex SHA-256 of the file at `url`.
    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Lowercase hex SHA-512 of the file at `url`.
    public static func sha512(of url: URL) throws -> String {
        var hasher = SHA512()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    private static func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            consume(chunk)
        }
    }

    private static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
