import Foundation

public enum ConfigWriterError: Error, Equatable, CustomStringConvertible {
    /// A generated file resolves outside `Paths.root`.
    case outsideRoot(String)

    public var description: String {
        switch self {
        case .outsideRoot(let p): return "Refusing to write outside RAMP root: \(p)"
        }
    }
}

/// The only generator component that touches disk. Writes a file only when its contents differ
/// (atomic temp + rename in the same directory) and returns the set of changed paths, so the
/// stack controller can decide which services need a reload.
public struct ConfigWriter: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// Deletes regular files with `ext` directly in `directory` that are not in `keeping` (e.g. a removed or
    /// disabled vhost). Never recurses, never follows or removes symlinks; a missing directory yields `[]`.
    /// - Returns: the removed file URLs.
    @discardableResult
    public func prune(directory: URL, keeping: Set<URL>, extension ext: String) throws -> Set<URL> {
        let dir = directory.standardizedFileURL
        try requireInsideRoot(dir)
        let fm = FileManager.default
        let dirPath = ConfigText.path(dir)
        // The directory itself must be a real directory (not a symlink pointing elsewhere).
        var st = stat()
        guard lstat(dirPath, &st) == 0 else { return [] }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return [] }

        let keep = Set(keeping.map { ConfigText.path($0.standardizedFileURL) })
        var removed = Set<URL>()
        for name in try fm.contentsOfDirectory(atPath: dirPath).sorted() {
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            guard url.pathExtension == ext, !keep.contains(ConfigText.path(url)) else { continue }
            var entry = stat()
            guard lstat(ConfigText.path(url), &entry) == 0, (entry.st_mode & S_IFMT) == S_IFREG else { continue }
            if unlink(ConfigText.path(url)) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            removed.insert(url)
        }
        return removed
    }

    private func requireInsideRoot(_ url: URL) throws {
        let rootComponents = paths.root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            throw ConfigWriterError.outsideRoot(url.standardizedFileURL.path(percentEncoded: false))
        }
    }

    @discardableResult
    public func write(_ files: [GeneratedFile]) throws -> Set<URL> {
        // Validate everything before writing anything.
        for file in files { try requireInsideRoot(file.path) }

        let fm = FileManager.default
        var changed = Set<URL>()
        for file in files {
            let url = file.path.standardizedFileURL
            let path = url.path(percentEncoded: false)
            let data = Data(file.contents.utf8)
            if let existing = fm.contents(atPath: path), existing == data {
                // Unchanged content: only repair permissions, no reload needed.
                if let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, mode != file.mode {
                    try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: path)
                }
                continue
            }
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let temp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
            let tempPath = temp.path(percentEncoded: false)
            guard fm.createFile(atPath: tempPath, contents: data, attributes: [.posixPermissions: file.mode]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tempPath])
            }
            // createFile honors umask; enforce the exact mode.
            try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: tempPath)
            if rename(tempPath, path) != 0 {
                let err = errno
                try? fm.removeItem(atPath: tempPath)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            changed.insert(file.path)
        }
        return changed
    }
}
