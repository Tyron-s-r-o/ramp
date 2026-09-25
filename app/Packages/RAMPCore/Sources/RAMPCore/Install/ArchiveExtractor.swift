import Foundation

/// Lists, validates and extracts package archives with the system `bsdtar` (`/usr/bin/tar`).
///
/// Security contract (fail closed):
/// - entries are listed with `tar -tf` and validated BEFORE extraction — absolute paths and any `..`
///   component are rejected;
/// - extraction never uses `-P`, so bsdtar additionally refuses `..`, absolute paths and writes through
///   symlinks on its own;
/// - after extraction (still inside staging) every symlink must resolve inside the package root.
///
/// Formats: `.tar.xz` (primary) and `.tar.gz`, both decoded by libarchive inside stock bsdtar
/// (liblzma/zlib are linked in). No external decompressor is ever run; `PATH` is `/usr/bin:/bin`.
/// Anything else (e.g. `.tar.zst`, which stock bsdtar can only handle via an external `zstd`) is
/// rejected with `InstallError.unsupportedArchiveFormat`.
public struct ArchiveExtractor: Sendable {
    /// Compression detected from the file's magic bytes (never from the file name).
    public enum Format: Sendable, Equatable {
        case xz, gzip

        /// bsdtar compression flag.
        var flag: String {
            switch self {
            case .xz: return "-J"
            case .gzip: return "-z"
            }
        }
    }

    public var tar: URL

    public init(tar: URL = URL(filePath: "/usr/bin/tar")) {
        self.tar = tar
    }

    var environment: [String: String] { ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"] }

    /// Detects the archive format; throws `unsupportedArchiveFormat` for anything but xz / gzip.
    public static func format(of archive: URL) throws -> Format {
        let magic: Data
        do {
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            magic = try handle.read(upToCount: 6) ?? Data()
        } catch {
            throw InstallError.extractionFailed("cannot read \(archive.lastPathComponent): \(error.localizedDescription)")
        }
        if magic.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if magic.starts(with: [0x1F, 0x8B]) { return .gzip }
        throw InstallError.unsupportedArchiveFormat(archive.lastPathComponent)
    }

    /// Entry names as stored in the archive.
    public func list(_ archive: URL) async throws -> [String] {
        let format = try Self.format(of: archive)
        let result = try await InstallProcess.run(tar, ["-t", format.flag, "-f", archive.path(percentEncoded: false)],
                                                  environment: environment)
        guard result.status == 0 else {
            throw InstallError.extractionFailed("tar -tf exited \(result.status): \(result.stderr)")
        }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Rejects absolute entries and entries with a `..` path component.
    public static func validate(entries: [String]) throws {
        for entry in entries {
            if entry.hasPrefix("/") || entry.hasPrefix("~") {
                throw InstallError.unsafeArchive(entry)
            }
            if entry.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
                throw InstallError.unsafeArchive(entry)
            }
        }
    }

    /// Lists + validates, then extracts `archive` into the (existing, empty) directory `destination`.
    public func extract(_ archive: URL, into destination: URL) async throws {
        try Self.validate(entries: try await list(archive))
        let result = try await InstallProcess.run(
            tar,
            ["-x", try Self.format(of: archive).flag, "-f", archive.path(percentEncoded: false),
             "-C", destination.path(percentEncoded: false), "--no-same-owner"],
            environment: environment)
        guard result.status == 0 else {
            throw InstallError.extractionFailed("tar -xf exited \(result.status): \(result.stderr)")
        }
        // Defensive: downloaded archives may carry quarantine; extracted binaries must not.
        _ = try? await InstallProcess.run(URL(filePath: "/usr/bin/xattr"),
                                          ["-dr", "com.apple.quarantine", destination.path(percentEncoded: false)],
                                          environment: environment)
    }

    /// Every symlink under `root` must be relative and resolve (lexically) inside `root`.
    /// Resolution is per link; a chain of links is safe because each hop is checked on its own.
    public static func validateSymlinks(in root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        guard let walker = fm.enumerator(atPath: rootPath) else { return }
        while let rel = walker.nextObject() as? String {
            let linkPath = (rootPath as NSString).appendingPathComponent(rel)
            guard let type = try? fm.attributesOfItem(atPath: linkPath)[.type] as? FileAttributeType,
                  type == .typeSymbolicLink else { continue }
            let target = try fm.destinationOfSymbolicLink(atPath: linkPath)
            if target.hasPrefix("/") || target.hasPrefix("~") {
                throw InstallError.unsafeArchive("\(rel) -> \(target)")
            }
            // Lexical resolution relative to the package root (no filesystem lookups).
            var parts = rel.split(separator: "/").dropLast().map(String.init)
            // `..` is only accepted as a leading component: `dir/..` could climb out through
            // another (individually harmless) symlink named `dir`.
            var escapes = false
            var seenName = false
            for component in target.split(separator: "/") where component != "." {
                if component == ".." {
                    if parts.isEmpty || seenName { escapes = true; break }
                    parts.removeLast()
                } else {
                    seenName = true
                    parts.append(String(component))
                }
            }
            if escapes {
                throw InstallError.unsafeArchive("\(rel) -> \(target)")
            }
        }
    }
}

/// Runs a child process and awaits its termination without blocking the caller's executor.
/// stdout/stderr go to temp files (no pipe-buffer deadlock on large `tar -tf` listings).
enum InstallProcess {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws -> Result {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let id = UUID().uuidString
        let outURL = tmp.appending(path: "ramp-proc-\(id).out")
        let errURL = tmp.appending(path: "ramp-proc-\(id).err")
        fm.createFile(atPath: outURL.path(percentEncoded: false), contents: nil)
        fm.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return Result(status: status, stdout: out, stderr: err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
