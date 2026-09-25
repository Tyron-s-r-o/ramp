import Foundation

/// Rendering, merging and parsing of the RAMP-managed block in a hosts file.
///
/// Content is treated as `\n`-separated lines (CRLF is not expected in /etc/hosts; a stray `\r`
/// at a line end is tolerated by marker detection and otherwise preserved byte-for-byte).
/// Everything outside the block is never modified.
public enum HostsBlock {
    /// Marker prefixes (recognized after trimming trailing whitespace).
    public static let beginMarker = "# RAMP BEGIN"
    public static let endMarker = "# RAMP END"
    /// Exact header line RAMP writes.
    public static let beginLine = "# RAMP BEGIN — managed by RAMP, do not edit (changes are overwritten)"
    public static let endLine = endMarker
    /// Maximum size (bytes) of a hosts file RAMP is willing to process.
    public static let maxFileSize = 1 << 20

    // MARK: - Public API

    /// Renders the block (no trailing newline): validated, deduplicated, sorted names;
    /// one `127.0.0.1` and one `::1` line per name, tab-separated.
    public static func render(names: [String]) throws -> String {
        renderNormalized(try normalize(names))
    }

    /// Returns `existing` with the RAMP block added, replaced or (for empty `names`) removed.
    public static func merge(existing: String, names: [String]) throws -> String {
        guard existing.utf8.count <= maxFileSize else { throw HostsError.fileTooLarge }
        let normalized = try normalize(names)
        guard let block = try locate(in: existing) else {
            guard !normalized.isEmpty else { return existing }
            var out = existing
            if !out.isEmpty {
                if !out.hasSuffixByte(0x0A) { out += "\n" }
                out += "\n"
            }
            return out + renderNormalized(normalized) + "\n"
        }
        if normalized.isEmpty {
            var start = block.start
            // Also drop the single blank line RAMP adds before the block.
            if start > existing.startIndex {
                let prev = existing.utf8.index(before: start)
                if existing.utf8[prev] == 0x0A,
                   prev == existing.startIndex || existing.utf8[existing.utf8.index(before: prev)] == 0x0A {
                    start = prev
                }
            }
            return String(existing[..<start]) + String(existing[block.endAfterNewline...])
        }
        return String(existing[..<block.start]) + renderNormalized(normalized) + String(existing[block.endLineEnd...])
    }

    /// Names in the current RAMP block (sorted, lowercased); `nil` when there is no block or it is malformed.
    public static func names(in content: String) -> [String]? {
        guard let block = try? locate(in: content) else { return nil }
        var found = Set<String>()
        for line in lines(of: String(content[block.bodyStart..<block.bodyEnd])) {
            found.formUnion(hostnames(onLine: line))
        }
        return found.sorted()
    }

    /// Which of `names` are also mapped on lines outside the RAMP block (user's own entries).
    public static func foreignEntries(in content: String, names: [String]) -> Set<String> {
        let block = try? locate(in: content)
        var mapped = Set<String>()
        for line in lines(of: content) {
            if let block, line.startIndex >= block.start, line.startIndex < block.endAfterNewline { continue }
            mapped.formUnion(hostnames(onLine: line))
        }
        return Set(names.filter { mapped.contains(key(for: $0)) })
    }

    // MARK: - Internals

    struct Location {
        /// Start of the BEGIN line.
        let start: String.Index
        /// Start of the line after BEGIN / start of the END line.
        let bodyStart: String.Index
        let bodyEnd: String.Index
        /// End of the END line (before its newline).
        let endLineEnd: String.Index
        /// After the END line's newline (or end of content).
        let endAfterNewline: String.Index
    }

    static func normalize(_ names: [String]) throws -> [String] {
        guard names.count <= Hostname.maxNames else { throw HostsError.tooManyNames(names.count) }
        var set = Set<String>()
        for name in names { set.insert(try Hostname.validate(name)) }
        return set.sorted()
    }

    static func renderNormalized(_ names: [String]) -> String {
        var out = [beginLine]
        out.reserveCapacity(names.count * 2 + 2)
        for name in names {
            out.append("127.0.0.1\t\(name)")
            out.append("::1\t\(name)")
        }
        out.append(endLine)
        return out.joined(separator: "\n")
    }

    /// Lines split on `\n` (byte-wise, so `\r\n` is not treated as one character); indices refer to `content`.
    static func lines(of content: String) -> [Substring] {
        content.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            content[$0.startIndex..<$0.endIndex]
        }
    }

    static func trimmedTrailing(_ line: Substring) -> Substring {
        var t = line
        while let c = t.unicodeScalars.last, c == " " || c == "\t" || c == "\r" {
            t = t[..<t.unicodeScalars.index(before: t.endIndex)]
        }
        return t
    }

    /// Finds exactly one well-formed block; `nil` when none; throws on anything ambiguous.
    static func locate(in content: String) throws -> Location? {
        var begin: Substring?
        var result: Location?
        for line in lines(of: content) {
            let t = trimmedTrailing(line)
            if t.hasPrefix(beginMarker) {
                if begin != nil { throw HostsError.malformedBlock("nested '\(beginMarker)' before '\(endMarker)'") }
                if result != nil { throw HostsError.malformedBlock("more than one RAMP block") }
                begin = line
            } else if t.hasPrefix(endMarker) {
                guard let b = begin else {
                    throw HostsError.malformedBlock(result == nil
                        ? "'\(endMarker)' without preceding '\(beginMarker)'"
                        : "extra '\(endMarker)' after the RAMP block")
                }
                let bodyStart = b.endIndex < content.endIndex ? content.utf8.index(after: b.endIndex) : b.endIndex
                let after = line.endIndex < content.endIndex ? content.utf8.index(after: line.endIndex) : line.endIndex
                result = Location(start: b.startIndex, bodyStart: bodyStart, bodyEnd: line.startIndex,
                                  endLineEnd: line.endIndex, endAfterNewline: after)
                begin = nil
            }
        }
        if begin != nil { throw HostsError.malformedBlock("'\(beginMarker)' without '\(endMarker)'") }
        return result
    }

    /// Hostnames (lowercased, one trailing dot stripped) mapped on a hosts line; comments ignored.
    static func hostnames(onLine line: Substring) -> [String] {
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        guard fields.count >= 2 else { return [] }
        return fields.dropFirst().map { key(for: String($0)) }
    }

    static func key(for name: String) -> String {
        if let valid = try? Hostname.validate(name) { return valid }
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        return n
    }
}

extension String {
    func hasSuffixByte(_ byte: UInt8) -> Bool { utf8.last == byte }
}
