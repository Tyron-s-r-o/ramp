import Foundation

/// One RESP2 / RESP3 reply. Bulk payloads stay `Data` (binary-safe); display goes through `RedisValueFormat`.
public indirect enum RESPValue: Sendable, Equatable {
    case simple(String)
    case error(String)
    case integer(Int64)
    case bulk(Data)
    case null
    case array([RESPValue])
    /// RESP3 `%` — ordered key/value pairs (keys may be any type).
    case map([RESPPair])
    /// RESP3 `~`.
    case set([RESPValue])
    /// RESP3 `>` out-of-band push.
    case push([RESPValue])
    /// RESP3 `,`.
    case double(Double)
    /// RESP3 `#`.
    case boolean(Bool)
    /// RESP3 `(` — kept as the decimal text.
    case bigNumber(String)
    /// RESP3 `=` — 3-char format (`txt`/`mkd`) + payload.
    case verbatim(format: String, Data)

    /// Text of simple/bulk/verbatim/bigNumber replies (UTF-8, lossy); `nil` for everything else.
    public var string: String? {
        switch self {
        case .simple(let s), .bigNumber(let s): s
        case .bulk(let d), .verbatim(_, let d): String(decoding: d, as: UTF8.self)
        case .integer(let i): String(i)
        case .double(let d): String(d)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .bulk(let d), .verbatim(_, let d): d
        case .simple(let s): Data(s.utf8)
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .integer(let i): i
        case .simple(let s), .bigNumber(let s): Int64(s)
        case .bulk(let d): Int64(String(decoding: d, as: UTF8.self))
        default: nil
        }
    }

    /// Elements of array/set/push replies; a RESP3 map flattens to `[k1, v1, k2, v2, …]` (RESP2 shape).
    public var elements: [RESPValue]? {
        switch self {
        case .array(let a), .set(let a), .push(let a): a
        case .map(let pairs): pairs.flatMap { [$0.key, $0.value] }
        default: nil
        }
    }

    public var isNull: Bool { self == .null }
}

public struct RESPPair: Sendable, Equatable {
    public var key: RESPValue
    public var value: RESPValue
    public init(_ key: RESPValue, _ value: RESPValue) {
        self.key = key
        self.value = value
    }
}

public enum RESPError: Error, Equatable, LocalizedError {
    case protocolError(String)
    case server(String)
    case timeout
    case connectionClosed
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let m): "Redis protocol error: \(m)"
        case .server(let m): m
        case .timeout: "Redis did not answer within the timeout."
        case .connectionClosed: "Redis closed the connection."
        case .connectionFailed(let m): "Cannot connect to Redis: \(m)"
        }
    }
}

/// Incremental RESP parser: `append` bytes as they arrive, `next()` returns a complete reply or `nil`
/// when more bytes are needed (partial reads never lose data).
public struct RESPParser: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    /// Bulk / aggregate sanity caps (Redis' own proto-max-bulk-len default is 512 MB).
    public static let maxBulk = 512 * 1024 * 1024
    public static let maxDepth = 64

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// Bytes not consumed yet.
    public var pending: Int { buffer.count - start }

    public mutating func next() throws -> RESPValue? {
        var index = start
        guard let value = try parse(at: &index, depth: 0) else { return nil }
        start = index
        if start > 64 * 1024, start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        } else if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        return value
    }

    /// Parses a complete buffer (tests / one-shot use); throws if incomplete or trailing bytes remain.
    public static func parse(_ data: Data) throws -> RESPValue {
        var p = RESPParser()
        p.append(data)
        guard let v = try p.next() else { throw RESPError.protocolError("incomplete reply") }
        guard p.pending == 0 else { throw RESPError.protocolError("trailing bytes") }
        return v
    }

    // MARK: Internals

    /// Index of the `\r` of the next CRLF at or after `from`, or `nil` if not buffered yet.
    private func lineEnd(from: Int) -> Int? {
        var i = from
        while i + 1 < buffer.count {
            if buffer[i] == 0x0D && buffer[i + 1] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    private func line(_ index: inout Int) -> String? {
        guard let end = lineEnd(from: index) else { return nil }
        let s = String(decoding: buffer[index..<end], as: UTF8.self)
        index = end + 2
        return s
    }

    private func length(_ text: String) throws -> Int {
        guard let n = Int(text), n >= -1 else { throw RESPError.protocolError("bad length '\(text)'") }
        return n
    }

    private func parse(at index: inout Int, depth: Int) throws -> RESPValue? {
        guard depth <= Self.maxDepth else { throw RESPError.protocolError("nesting too deep") }
        guard index < buffer.count else { return nil }
        let type = buffer[index]
        var i = index + 1
        guard let header = line(&i) else { return nil }
        let value: RESPValue
        switch type {
        case UInt8(ascii: "+"):
            value = .simple(header)
        case UInt8(ascii: "-"):
            value = .error(header)
        case UInt8(ascii: ":"):
            guard let n = Int64(header) else { throw RESPError.protocolError("bad integer '\(header)'") }
            value = .integer(n)
        case UInt8(ascii: "_"):
            value = .null
        case UInt8(ascii: "#"):
            switch header {
            case "t": value = .boolean(true)
            case "f": value = .boolean(false)
            default: throw RESPError.protocolError("bad boolean '\(header)'")
            }
        case UInt8(ascii: ","):
            switch header.lowercased() {
            case "inf": value = .double(.infinity)
            case "-inf": value = .double(-.infinity)
            case "nan": value = .double(.nan)
            default:
                guard let d = Double(header) else { throw RESPError.protocolError("bad double '\(header)'") }
                value = .double(d)
            }
        case UInt8(ascii: "("):
            value = .bigNumber(header)
        case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
            let n = try length(header)
            if n == -1 {
                value = .null
                break
            }
            guard n <= Self.maxBulk else { throw RESPError.protocolError("bulk too large (\(n))") }
            guard buffer.count >= i + n + 2 else { return nil }
            guard buffer[i + n] == 0x0D, buffer[i + n + 1] == 0x0A else {
                throw RESPError.protocolError("bulk not terminated by CRLF")
            }
            let payload = Data(buffer[i..<(i + n)])
            i += n + 2
            if type == UInt8(ascii: "!") {
                value = .error(String(decoding: payload, as: UTF8.self))
            } else if type == UInt8(ascii: "=") {
                // "txt:" prefix (3-char format + colon).
                if payload.count >= 4, payload[payload.startIndex + 3] == UInt8(ascii: ":") {
                    value = .verbatim(format: String(decoding: payload.prefix(3), as: UTF8.self),
                                      Data(payload.dropFirst(4)))
                } else {
                    value = .verbatim(format: "txt", payload)
                }
            } else {
                value = .bulk(payload)
            }
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"):
            let n = try length(header)
            if n == -1 {
                value = .null
                break
            }
            var items: [RESPValue] = []
            items.reserveCapacity(min(n, 4096))
            for _ in 0..<n {
                guard let item = try parse(at: &i, depth: depth + 1) else { return nil }
                items.append(item)
            }
            value = type == UInt8(ascii: "*") ? .array(items) : type == UInt8(ascii: "~") ? .set(items) : .push(items)
        case UInt8(ascii: "%"), UInt8(ascii: "|"):
            let n = try length(header)
            var pairs: [RESPPair] = []
            for _ in 0..<max(n, 0) {
                guard let k = try parse(at: &i, depth: depth + 1) else { return nil }
                guard let v = try parse(at: &i, depth: depth + 1) else { return nil }
                pairs.append(RESPPair(k, v))
            }
            if type == UInt8(ascii: "|") {
                // Attribute: metadata preceding the real reply — skip it, return the reply.
                guard let real = try parse(at: &i, depth: depth + 1) else { return nil }
                index = i
                return real
            }
            value = .map(pairs)
        default:
            throw RESPError.protocolError("unknown type byte 0x\(String(type, radix: 16))")
        }
        index = i
        return value
    }
}

/// Encodes a command as a RESP array of bulk strings (the only request form Redis accepts besides inline).
public enum RESPEncoder {
    public static func command(_ args: [Data]) -> Data {
        var out = Data("*\(args.count)\r\n".utf8)
        for arg in args {
            out.append(contentsOf: Array("$\(arg.count)\r\n".utf8))
            out.append(arg)
            out.append(contentsOf: [0x0D, 0x0A])
        }
        return out
    }

    public static func command(_ args: [String]) -> Data {
        command(args.map { Data($0.utf8) })
    }
}
