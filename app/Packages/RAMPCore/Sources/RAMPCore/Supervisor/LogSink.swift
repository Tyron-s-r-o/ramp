import Foundation

/// Per-service log file `<logs>/<service>.log` used as the child's stdout + stderr.
public struct LogSink: Sendable {
    public static let defaultRotateBytes: UInt64 = 50 * 1024 * 1024

    public let paths: Paths
    public let rotateBytes: UInt64

    public init(paths: Paths, rotateBytes: UInt64 = LogSink.defaultRotateBytes) {
        self.paths = paths
        self.rotateBytes = rotateBytes
    }

    public func url(service: String) -> URL { paths.log("\(service).log") }

    /// Opens the log for appending (O_APPEND, created 0644). If it is larger than `rotateBytes`
    /// it is first moved to `<service>.log.1` (the previous `.1` is replaced).
    public func open(service: String) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let url = url(service: service)
        let path = url.path(percentEncoded: false)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > rotateBytes {
            let rotated = path + ".1"
            try? fm.removeItem(atPath: rotated)
            try fm.moveItem(atPath: path, toPath: rotated)
        }
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path,
                                                           NSUnderlyingErrorKey: POSIXError(.init(rawValue: errno) ?? .EIO)])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Writes `=== RAMP <text> === <timestamp>` to the log.
    public static func marker(_ handle: FileHandle, _ text: String, date: Date = .now) {
        let line = "\(date.ISO8601Format()) === RAMP \(text) ===\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
