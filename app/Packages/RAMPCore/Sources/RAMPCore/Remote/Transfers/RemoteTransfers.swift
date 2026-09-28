import Foundation

/// What to do when the destination file already exists.
public enum ConflictPolicy: String, Sendable, Hashable, CaseIterable {
    case overwrite
    case skip
}

/// Progress of a whole batch (all files of one download / upload call).
public struct TransferProgress: Sendable, Hashable {
    /// Remote path (download) or local path (upload) of the file being transferred.
    public var currentPath: String
    public var bytesDone: Int64
    /// Sum of all file sizes in the batch; nil when a size is unknown.
    public var bytesTotal: Int64?
    public var filesDone: Int
    public var filesTotal: Int

    public init(currentPath: String, bytesDone: Int64, bytesTotal: Int64?, filesDone: Int, filesTotal: Int) {
        self.currentPath = currentPath
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }

    /// 0…1, by bytes when the total is known, else by files.
    public var fraction: Double {
        if let t = bytesTotal, t > 0 { return min(1, Double(bytesDone) / Double(t)) }
        return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
}

/// Recursive transfers on top of any `RemoteFileSystem` (pure orchestration, no protocol code).
/// The tree is scanned first so progress has whole-batch totals. Symlinks on the server are
/// skipped on download (never followed); Task cancellation is checked between files and the
/// file system aborts the file in flight.
public enum RemoteTransfers {
    public typealias Progress = @Sendable (TransferProgress) -> Void

    // MARK: Download

    public static func downloadTree(_ fs: any RemoteFileSystem, item: RemoteItem, into localDir: URL,
                                    conflict: ConflictPolicy, progress: @escaping Progress) async throws {
        try await download(fs, items: [item], into: localDir, conflict: conflict, progress: progress)
    }

    /// Downloads files and folders (recursively) into `localDir` as `<localDir>/<item.name>`.
    public static func download(_ fs: any RemoteFileSystem, items: [RemoteItem], into localDir: URL,
                                conflict: ConflictPolicy, progress: @escaping Progress) async throws {
        var dirs: [URL] = []
        var files: [(RemoteItem, URL)] = []
        for item in items {
            try await planDownload(fs, item: item, local: localDir.appending(path: item.name), dirs: &dirs, files: &files)
        }
        let known = files.compactMap(\.0.size)
        var state = TransferProgress(currentPath: items.first?.path ?? "", bytesDone: 0,
                                     bytesTotal: known.count == files.count ? known.reduce(0, +) : nil,
                                     filesDone: 0, filesTotal: files.count)
        progress(state)

        let fm = FileManager.default
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        for dir in dirs {
            try Task.checkCancellation()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for (remote, local) in files {
            try Task.checkCancellation()
            state.currentPath = remote.path
            let size = remote.size ?? 0
            if conflict == .skip, fm.fileExists(atPath: local.path(percentEncoded: false)) {
                state.bytesDone += size
                state.filesDone += 1
                progress(state)
                continue
            }
            let base = state
            progress(base)
            try await fs.download(remote.path, to: local) { done, _ in
                var p = base
                p.bytesDone = base.bytesDone + done
                progress(p)
            }
            state.bytesDone += size
            state.filesDone += 1
            progress(state)
        }
    }

    private static func planDownload(_ fs: any RemoteFileSystem, item: RemoteItem, local: URL,
                                     dirs: inout [URL], files: inout [(RemoteItem, URL)]) async throws {
        try Task.checkCancellation()
        switch item.kind {
        case .symlink:
            return
        case .file:
            files.append((item, local))
        case .directory:
            dirs.append(local)
            for child in try await fs.list(item.path).sorted(by: { $0.name < $1.name }) {
                try await planDownload(fs, item: child, local: local.appending(path: child.name), dirs: &dirs, files: &files)
            }
        }
    }

    /// Names of `items` that already exist in `localDir` (ask the user once before `download`).
    public static func conflicts(downloading items: [RemoteItem], into localDir: URL) -> [String] {
        items.map(\.name).filter { FileManager.default.fileExists(atPath: localDir.appending(path: $0).path(percentEncoded: false)) }
    }

    // MARK: Upload

    public static func uploadTree(_ fs: any RemoteFileSystem, localURL: URL, intoRemoteDir remoteDir: String,
                                  conflict: ConflictPolicy, progress: @escaping Progress) async throws {
        try await upload(fs, localURLs: [localURL], intoRemoteDir: remoteDir, conflict: conflict, progress: progress)
    }

    /// Uploads local files and folders (recursively) into `remoteDir`, creating remote folders.
    /// Existing remote folders are merged; files follow `conflict`.
    public static func upload(_ fs: any RemoteFileSystem, localURLs: [URL], intoRemoteDir remoteDir: String,
                              conflict: ConflictPolicy, progress: @escaping Progress) async throws {
        var steps: [UploadStep] = []
        for url in localURLs {
            try planUpload(url, remote: RemotePath.join(remoteDir, url.lastPathComponent), steps: &steps)
        }
        let fileSteps = steps.filter { !$0.isDirectory }
        var state = TransferProgress(currentPath: localURLs.first?.path(percentEncoded: false) ?? "", bytesDone: 0,
                                     bytesTotal: fileSteps.reduce(0) { $0 + $1.size }, filesDone: 0,
                                     filesTotal: fileSteps.count)
        progress(state)

        var existing = ExistingNames(fs: fs)
        for step in steps {
            try Task.checkCancellation()
            let parent = RemotePath.parent(step.remote)
            let name = RemotePath.name(step.remote)
            let already = try await existing.kind(of: name, in: parent)
            if step.isDirectory {
                switch already {
                case .directory: break
                case .some: throw RemoteError.alreadyExists(step.remote)
                case nil:
                    try await fs.createDirectory(step.remote)
                    existing.add(name, kind: .directory, in: parent)
                    existing.markEmpty(step.remote)
                }
                continue
            }
            state.currentPath = step.local.path(percentEncoded: false)
            if already == .directory { throw RemoteError.alreadyExists(step.remote) }
            if already != nil, conflict == .skip {
                state.bytesDone += step.size
                state.filesDone += 1
                progress(state)
                continue
            }
            let base = state
            progress(base)
            try await fs.upload(step.local, to: step.remote) { done, _ in
                var p = base
                p.bytesDone = base.bytesDone + done
                progress(p)
            }
            existing.add(name, kind: .file, in: parent)
            state.bytesDone += step.size
            state.filesDone += 1
            progress(state)
        }
    }

    /// Names of `localURLs` that already exist in `remoteDir` (ask the user once before `upload`).
    public static func conflicts(uploading localURLs: [URL], intoRemoteDir remoteDir: String,
                                 fs: any RemoteFileSystem) async throws -> [String] {
        let names: Set<String>
        do {
            names = Set(try await fs.list(remoteDir).map(\.name))
        } catch RemoteError.notFound {
            return []
        }
        return localURLs.map(\.lastPathComponent).filter { names.contains($0) }
    }

    private struct UploadStep {
        var local: URL
        var remote: String
        var isDirectory: Bool
        var size: Int64
    }

    private static func planUpload(_ url: URL, remote: String, steps: inout [UploadStep]) throws {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            // Follow links to files; never recurse into linked folders (loops).
            let target = url.resolvingSymlinksInPath()
            let tv = try target.resourceValues(forKeys: keys)
            guard tv.isRegularFile == true else { return }
            steps.append(UploadStep(local: url, remote: remote, isDirectory: false, size: Int64(tv.fileSize ?? 0)))
            return
        }
        if values.isDirectory == true {
            steps.append(UploadStep(local: url, remote: remote, isDirectory: true, size: 0))
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try planUpload(child, remote: RemotePath.join(remote, child.lastPathComponent), steps: &steps)
            }
        } else if values.isRegularFile == true {
            steps.append(UploadStep(local: url, remote: remote, isDirectory: false, size: Int64(values.fileSize ?? 0)))
        }
    }

    /// Lazily listed remote folders → names and kinds (one `list` per folder).
    private struct ExistingNames {
        let fs: any RemoteFileSystem
        var cache: [String: [String: RemoteItem.Kind]] = [:]

        init(fs: any RemoteFileSystem) { self.fs = fs }

        mutating func kind(of name: String, in dir: String) async throws -> RemoteItem.Kind? {
            if let names = cache[dir] { return names[name] }
            var names: [String: RemoteItem.Kind] = [:]
            do {
                for item in try await fs.list(dir) { names[item.name] = item.kind }
            } catch RemoteError.notFound {
                // Parent does not exist yet — createDirectory / upload will report it.
            }
            cache[dir] = names
            return names[name]
        }

        mutating func add(_ name: String, kind: RemoteItem.Kind, in dir: String) {
            cache[dir, default: [:]][name] = kind
        }

        mutating func markEmpty(_ dir: String) {
            cache[dir] = [:]
        }
    }

    // MARK: Delete

    /// Deletes a file, symlink or folder (depth-first: contents, then the folder itself).
    public static func deleteTree(_ fs: any RemoteFileSystem, item: RemoteItem) async throws {
        try Task.checkCancellation()
        if item.kind == .directory {
            for child in try await fs.list(item.path) {
                try await deleteTree(fs, item: child)
            }
        }
        try await fs.delete(item)
    }
}
