import Darwin
import Foundation
import Synchronization

/// What happens with one entry of a MySQL 8.0 datadir during the MAMP import copy (plan 07-04).
public enum DatadirEntryCategory: String, Sendable, Equatable, Codable {
    case copy
    /// `binlog.000123`, `binlog.index` (+ `<name>-bin.*`): never copied (187 GB on the author's machine).
    case binlog
    /// `*.log` (error / general / slow logs).
    case log
    /// `.DS_Store`, `mysqld-auto.cnf` (persisted 8.0 vars can abort 8.4/9.7), `#innodb_temp/`, `ibtmp1`,
    /// pid/socket leftovers — recreated by the server or harmful.
    case excluded
}

/// Pure exclusion rules for the datadir copy.
public enum DatadirExclusion {
    /// Classifies a path relative to the datadir root (`"binlog.000001"`, `"app_one/t.ibd"`, `"#innodb_temp"`).
    public static func classify(relativePath: String, isDirectory: Bool) -> DatadirEntryCategory {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last else { return .excluded }
        if name == ".DS_Store" { return .excluded }
        let topLevel = components.count == 1
        if isDirectory {
            return topLevel && name == "#innodb_temp" ? .excluded : .copy
        }
        if name.hasSuffix(".log") { return .log }
        guard topLevel else { return .copy }
        if isBinlog(name) { return .binlog }
        if ["mysqld-auto.cnf", "ibtmp1", "mysql.sock", "mysql.sock.lock", "mysqlx.sock", "mysqlx.sock.lock"]
            .contains(name) || name.hasSuffix(".pid") {
            return .excluded
        }
        return .copy
    }

    /// `binlog.000001` / `binlog.index` / `mysql-bin.000001` / `host-bin.index` (top level only).
    public static func isBinlog(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let base = name[..<dot]
        let ext = name[name.index(after: dot)...]
        guard base == "binlog" || base.hasSuffix("-bin") else { return false }
        return ext == "index" || (ext.count >= 6 && ext.allSatisfy(\.isASCII) && ext.allSatisfy(\.isNumber))
    }
}

/// One regular file of a scanned datadir.
public struct DatadirFile: Sendable, Equatable {
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    public var category: DatadirEntryCategory
}

/// Size breakdown of a datadir.
public struct DatadirSizes: Sendable, Equatable, Codable {
    public var totalBytes: Int64 = 0
    public var binlogBytes: Int64 = 0
    public var logBytes: Int64 = 0
    public var excludedBytes: Int64 = 0
    public var toCopyBytes: Int64 = 0
    public var fileCount = 0
    public var toCopyFiles = 0

    public init() {}

    mutating func add(_ file: DatadirFile) {
        totalBytes += file.size
        fileCount += 1
        switch file.category {
        case .copy:
            toCopyBytes += file.size
            toCopyFiles += 1
        case .binlog: binlogBytes += file.size
        case .log: logBytes += file.size
        case .excluded: excludedBytes += file.size
        }
    }
}

/// Result of walking a datadir (never follows symlinks, never writes).
public struct DatadirScan: Sendable {
    public var files: [DatadirFile] = []
    /// Directories to create (relative), in walk order (parents first).
    public var directories: [String] = []
    /// Symlinks whose target stays inside the datadir: relative path → link destination (as stored).
    public var internalSymlinks: [String: String] = [:]
    public var warnings: [String] = []
    public var sizes = DatadirSizes()
    /// Schema directory names as stored on disk (`app@002dtwo`), system schemas and `#…` excluded.
    public var schemaDirectories: [String] = []
}

/// Progress of a running copy.
public struct DatadirCopyProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentFile: String
}

public struct DatadirCopyReport: Sendable, Equatable {
    public var filesCopied = 0
    public var filesSkipped = 0
    public var bytes: Int64 = 0
    public var cloned = 0
    public var warnings: [String] = []
}

public enum DatadirCopyError: Error, LocalizedError, Equatable {
    case sourceUnreadable(String)
    case copyFailed(path: String, errno: Int32)
    case destinationInsideSource
    case cancelled
    /// Test hook (`RAMP_TEST_FAIL_AFTER_FILES`): simulated interruption after N copied files.
    case simulatedInterruption(Int)

    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let p): "Source datadir is not readable: \(p)"
        case .copyFailed(let p, let e): "Copying \(p) failed: \(String(cString: strerror(e)))"
        case .destinationInsideSource: "The copy destination must not be inside the source datadir."
        case .cancelled: "Copy cancelled."
        case .simulatedInterruption(let n): "Simulated interruption after \(n) files (test hook)."
        }
    }
}

/// Copies a MySQL datadir without binlogs/logs (plan 07-04): APFS clone per file when possible
/// (`copyfile(COPYFILE_CLONE)` falls back to a data copy by itself), destination 0700 dirs / 0600 files,
/// resume skips destination files with the same size + mtime. The source is only ever opened read-only.
public struct DatadirCopier: Sendable {
    public static let systemSchemas: Set<String> = ["mysql", "sys", "performance_schema", "information_schema"]

    public init() {}

    /// Walks `source` without following symlinks.
    public func scan(_ source: URL) throws -> DatadirScan {
        let fm = FileManager.default
        let rootPath = source.standardizedFileURL.path(percentEncoded: false).trimmingSlash
        guard fm.isReadableFile(atPath: rootPath) else { throw DatadirCopyError.sourceUnreadable(rootPath) }
        // Path-based enumerator: relative paths, symlinks are reported, never followed.
        guard let walker = fm.enumerator(atPath: rootPath) else { throw DatadirCopyError.sourceUnreadable(rootPath) }
        var scan = DatadirScan()
        while let rel = walker.nextObject() as? String {
            let path = rootPath + "/" + rel
            var st = stat()
            guard lstat(path, &st) == 0 else {
                scan.warnings.append("\(rel): \(String(cString: strerror(errno)))")
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                let dest = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
                let parent = (rel as NSString).deletingLastPathComponent
                let absolute = dest.hasPrefix("/") ? dest
                    : rootPath + "/" + (parent.isEmpty ? "" : parent + "/") + dest
                let target = URL(filePath: absolute).standardizedFileURL.path(percentEncoded: false)
                if !dest.isEmpty, target.hasPrefix(rootPath + "/") {
                    scan.internalSymlinks[rel] = dest
                } else {
                    scan.warnings.append("symlink \(rel) → \(dest) points outside the datadir — skipped")
                }
            case S_IFDIR:
                if DatadirExclusion.classify(relativePath: rel, isDirectory: true) != .copy {
                    walker.skipDescendants()
                    continue
                }
                scan.directories.append(rel)
                if !rel.contains("/"), !rel.hasPrefix("#"), !Self.systemSchemas.contains(rel) {
                    scan.schemaDirectories.append(rel)
                }
            case S_IFREG:
                let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)
                                    + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
                let file = DatadirFile(relativePath: rel, size: Int64(st.st_size), modified: modified,
                                       category: DatadirExclusion.classify(relativePath: rel, isDirectory: false))
                scan.files.append(file)
                scan.sizes.add(file)
            default:
                scan.warnings.append("\(rel) is not a regular file — skipped")
            }
        }
        scan.schemaDirectories.sort()
        return scan
    }

    /// Copies every `.copy` entry of `scan` from `source` into `destination`.
    /// - Parameters:
    ///   - isCancelled: polled between files.
    ///   - interruptAfter: test hook — throws `.simulatedInterruption` after that many newly copied files.
    public func copy(_ scan: DatadirScan, from source: URL, to destination: URL,
                     interruptAfter: Int? = nil,
                     isCancelled: @Sendable () -> Bool = { false },
                     progress: @Sendable (DatadirCopyProgress) -> Void = { _ in }) throws -> DatadirCopyReport {
        let fm = FileManager.default
        let src = URL(filePath: source.standardizedFileURL.path(percentEncoded: false).trimmingSlash, directoryHint: .isDirectory)
        let dst = destination.standardizedFileURL
        let srcPath = src.path(percentEncoded: false)
        let dstPath = dst.path(percentEncoded: false)
        if dstPath == srcPath || dstPath.hasPrefix(srcPath.hasSuffix("/") ? srcPath : srcPath + "/") {
            throw DatadirCopyError.destinationInsideSource
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dstPath, 0o700)
        for dir in scan.directories {
            let d = dst.appending(path: dir, directoryHint: .isDirectory)
            try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(d.path(percentEncoded: false), 0o700)
        }

        let toCopy = scan.files.filter { $0.category == .copy }
        let bytesTotal = toCopy.reduce(Int64(0)) { $0 + $1.size }
        var report = DatadirCopyReport(warnings: scan.warnings)
        var done = 0
        var bytesDone: Int64 = 0
        var lastReport = ContinuousClock.now
        let clock = ContinuousClock()
        for file in toCopy {
            if isCancelled() { throw DatadirCopyError.cancelled }
            let from = src.appending(path: file.relativePath, directoryHint: .notDirectory).path(percentEncoded: false)
            let to = dst.appending(path: file.relativePath, directoryHint: .notDirectory).path(percentEncoded: false)
            if Self.sameFile(destination: to, as: file) {
                report.filesSkipped += 1
            } else {
                if let limit = interruptAfter, report.filesCopied >= limit {
                    throw DatadirCopyError.simulatedInterruption(limit)
                }
                unlink(to)   // COPYFILE_CLONE implies COPYFILE_EXCL (partial file from an interrupted run)
                let cloneBefore = Self.isClonePossible(from: from, to: (to as NSString).deletingLastPathComponent)
                // COPYFILE_CLONE = best effort clone, falls back to a data copy; NOFOLLOW_SRC included.
                if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                    let e = errno
                    unlink(to)
                    // Plain data + stat copy (no clone, no ACL/xattr).
                    if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC)) != 0 {
                        throw DatadirCopyError.copyFailed(path: file.relativePath, errno: e)
                    }
                } else if cloneBefore {
                    report.cloned += 1
                }
                chmod(to, 0o600)
                Self.setModificationDate(to, file.modified)
                report.filesCopied += 1
                report.bytes += file.size
            }
            done += 1
            bytesDone += file.size
            let now = clock.now
            if now - lastReport >= .milliseconds(250) || done == toCopy.count {
                lastReport = now
                progress(DatadirCopyProgress(filesDone: done, filesTotal: toCopy.count, bytesDone: bytesDone,
                                             bytesTotal: bytesTotal, currentFile: file.relativePath))
            }
        }
        for (rel, target) in scan.internalSymlinks.sorted(by: { $0.key < $1.key }) {
            let link = dst.appending(path: rel, directoryHint: .notDirectory).path(percentEncoded: false)
            unlink(link)
            if symlink(target, link) != 0 {
                report.warnings.append("cannot recreate symlink \(rel) → \(target)")
            }
        }
        if toCopy.isEmpty {
            progress(DatadirCopyProgress(filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0, currentFile: ""))
        }
        return report
    }

    /// Resume check: destination exists as a regular file with the source's size and mtime.
    static func sameFile(destination: String, as file: DatadirFile) -> Bool {
        var st = stat()
        guard lstat(destination, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return Int64(st.st_size) == file.size && abs(mtime - file.modified.timeIntervalSince1970) < 0.001
    }

    private static func setModificationDate(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Same volume and the volume supports cloning (APFS).
    static func isClonePossible(from source: String, to destinationDir: String) -> Bool {
        var a = stat(), b = stat()
        guard stat(source, &a) == 0, stat(destinationDir, &b) == 0, a.st_dev == b.st_dev else { return false }
        let url = URL(filePath: destinationDir)
        return (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }

    /// Same volume + cloning support between a source dir and a (possibly not yet existing) destination:
    /// walks up to the first existing ancestor of `destination`.
    public static func clonePossible(source: URL, destination: URL) -> Bool {
        var dir = destination.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: dir.path(percentEncoded: false)), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        return isClonePossible(from: source.path(percentEncoded: false), to: dir.path(percentEncoded: false))
    }
}

/// Cancellation flag shared with blocking work running outside the cooperative pool.
public final class CancelFlag: Sendable {
    private let value = Mutex(false)
    public init() {}
    public func cancel() { value.withLock { $0 = true } }
    public var isCancelled: Bool { value.withLock { $0 } }
}

extension String {
    /// Path without trailing slashes ("/" stays "/").
    var trimmingSlash: String {
        var s = self
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
