import Foundation

/// Incremental reader of one growing log file (`tail -F` semantics) as a plain value type.
///
/// Strategy: poll, not `DispatchSource` — every `poll()` opens the path fresh, `fstat`s it and compares
/// the inode and size with what was read so far:
/// - file missing → nothing (state forgotten; when it reappears the next poll reports `reset`);
/// - inode changed (LogSink renamed it to `.1` and a new file was created) → `reset`, read from 0;
/// - size < offset (truncated) → `reset`, read from 0;
/// - otherwise the new bytes (at most `maxPollBytes` per poll — catch-up happens in chunks).
/// Only complete lines are returned; a trailing partial line is kept until its `\n` arrives.
/// Invalid UTF-8 is decoded lossily.
public struct LogTailReader: Sendable {
    public struct PollResult: Sendable, Equatable {
        public var lines: [String]
        /// The file was replaced / truncated / (re)appeared: the caller should discard what it shows.
        public var reset: Bool

        public init(lines: [String], reset: Bool) {
            self.lines = lines
            self.reset = reset
        }
    }

    public static let maxPollBytes = 4 * 1024 * 1024
    /// A "line" without `\n` longer than this is emitted as is (protects the buffer against binary junk).
    public static let maxPartialBytes = 1024 * 1024

    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()

    public init(url: URL) {
        self.url = url
    }

    /// Reads the tail of the file: at most `maxBytes` from its end, at most `maxLines` lines.
    /// When the read does not start at offset 0 the first (cut) line is dropped. A missing file yields `[]`.
    public mutating func initial(maxBytes: Int = 512 * 1024, maxLines: Int = 2000) throws -> [String] {
        partial = Data()
        offset = 0
        inode = nil
        guard let file = try Self.open(url) else { return [] }
        defer { close(file.fd) }
        inode = file.inode
        let start = file.size > UInt64(maxBytes) ? file.size - UInt64(maxBytes) : 0
        var data = try Self.read(fd: file.fd, from: start, count: Int(file.size - start))
        offset = start + UInt64(data.count)
        if start > 0 {
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            } else {
                // No line boundary in the whole window: everything is one cut line.
                partial = data
                return []
            }
        }
        return Array(consume(data).suffix(max(0, maxLines)))
    }

    /// New complete lines since the last call (see type docs for reset rules).
    public mutating func poll() throws -> PollResult {
        guard let file = try Self.open(url) else {
            inode = nil
            offset = 0
            partial = Data()
            return PollResult(lines: [], reset: false)
        }
        defer { close(file.fd) }
        var reset = false
        if inode != file.inode || file.size < offset {
            reset = true
            inode = file.inode
            offset = 0
            partial = Data()
        }
        guard file.size > offset else { return PollResult(lines: [], reset: reset) }
        let count = Int(min(file.size - offset, UInt64(Self.maxPollBytes)))
        let data = try Self.read(fd: file.fd, from: offset, count: count)
        offset += UInt64(data.count)
        return PollResult(lines: consume(data), reset: reset)
    }

    /// Appends `data` to the partial buffer, returns the complete lines, keeps the rest.
    private mutating func consume(_ data: Data) -> [String] {
        partial.append(data)
        var lines: [String] = []
        var lineStart = partial.startIndex
        var index = partial.startIndex
        while index < partial.endIndex {
            if partial[index] == 0x0A {
                lines.append(Self.decode(partial[lineStart..<index]))
                lineStart = partial.index(after: index)
            }
            index = partial.index(after: index)
        }
        partial = partial.subdata(in: lineStart..<partial.endIndex)
        if partial.count > Self.maxPartialBytes {
            lines.append(Self.decode(partial[...]))
            partial = Data()
        }
        return lines
    }

    private static func decode(_ bytes: Data.SubSequence) -> String {
        var slice = bytes
        if slice.last == 0x0D { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }

    private struct OpenFile {
        var fd: Int32
        var inode: UInt64
        var size: UInt64
    }

    /// nil when the file does not exist.
    private static func open(_ url: URL) throws -> OpenFile? {
        let path = url.path(percentEncoded: false)
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return OpenFile(fd: fd, inode: UInt64(st.st_ino), size: UInt64(max(0, st.st_size)))
    }

    private static func read(fd: Int32, from offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + total, count - total, off_t(offset) + off_t(total))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }   // file shrank between fstat and read
            total += n
        }
        return Data(buffer.prefix(total))
    }
}
