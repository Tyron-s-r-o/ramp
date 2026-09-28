import Foundation
import Synchronization

/// Plain (unencrypted) metadata of saved FTP/SFTP sites: `<root>/remote/sites.json`.
///
/// The list is readable without the master password; secrets live in `SiteVault`.
/// - `load()`: missing file → `[]`; corrupt file → throws (file left untouched, never wiped).
/// - `save(_:)`: previous file copied to `sites.json.bak`, new content written atomically (0600,
///   directory 0700), sites sorted by group then name.
public final class SiteStore: Sendable {
    public let url: URL
    /// Serializes load → mutate → save sequences.
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    private struct FileFormat: Codable {
        var version: Int
        var sites: [RemoteSite]
    }

    public func load() throws -> [RemoteSite] {
        try lock.withLock { _ in try loadUnlocked() }
    }

    public func save(_ sites: [RemoteSite]) throws {
        try lock.withLock { _ in try saveUnlocked(sites) }
    }

    /// Inserts or replaces (by id) one site; returns the saved, sorted list.
    @discardableResult
    public func upsert(_ site: RemoteSite) throws -> [RemoteSite] {
        try lock.withLock { _ in
            var sites = try loadUnlocked()
            if let i = sites.firstIndex(where: { $0.id == site.id }) {
                sites[i] = site
            } else {
                sites.append(site)
            }
            return try saveUnlocked(sites)
        }
    }

    /// Removes one site (no-op when missing); returns the saved, sorted list.
    @discardableResult
    public func delete(id: UUID) throws -> [RemoteSite] {
        try lock.withLock { _ in
            let sites = try loadUnlocked().filter { $0.id != id }
            return try saveUnlocked(sites)
        }
    }

    /// Distinct non-empty group names, sorted. Unreadable file → `[]`.
    public func groups() -> [String] {
        let sites = (try? load()) ?? []
        let names = Set(sites.compactMap { $0.group?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Group (nil / "" first) then name, Finder-like comparison.
    public static func sorted(_ sites: [RemoteSite]) -> [RemoteSite] {
        sites.sorted { a, b in
            let ga = a.group ?? "", gb = b.group ?? ""
            let g = ga.localizedStandardCompare(gb)
            if g != .orderedSame { return g == .orderedAscending }
            let n = a.name.localizedStandardCompare(b.name)
            if n != .orderedSame { return n == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    // MARK: Private

    private func loadUnlocked() throws -> [RemoteSite] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        do {
            return try JSONDecoder().decode(FileFormat.self, from: data).sites
        } catch {
            throw RemoteError.protocolError(
                "Súbor so zoznamom prístupov je poškodený (\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func saveUnlocked(_ sites: [RemoteSite]) throws -> [RemoteSite] {
        let sorted = Self.sorted(sites)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(version: 1, sites: sorted))
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path(percentEncoded: false))
        }
        try SecureFile.writeAtomically(data, to: url)
        return sorted
    }
}

/// Atomic, owner-only file writes for the remote manager's files.
enum SecureFile {
    /// Creates the parent directory (0700), writes `data` to a 0600 temp file in the same directory
    /// (opened with O_EXCL, never world-readable) and renames it over `url`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false))

        let target = url.path(percentEncoded: false)
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp").path(percentEncoded: false)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(errno, temp) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(temp) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno, temp)
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw posixError(errno, temp) }
        guard rename(temp, target) == 0 else { throw posixError(errno, target) }
        ok = true
    }

    private static func posixError(_ code: Int32, _ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
