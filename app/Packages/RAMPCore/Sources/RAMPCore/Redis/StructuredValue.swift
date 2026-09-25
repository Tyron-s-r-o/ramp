import Foundation

/// Parsed JSON / PHP `serialize()` value for the structured (tree) view of Redis strings.
/// Order of array entries and object properties is always preserved.
public enum StructuredValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    /// PHP array (int/string keys) or JSON array (keys 0…n-1).
    case array([Entry])
    /// PHP object (`className` set) or JSON object (`className == nil`, all properties public).
    case object(className: String?, properties: [Property])
    /// PHP 8.1 enum `E:…:"Suit:Hearts"`.
    case enumCase(className: String, caseName: String)
    /// PHP `r:n;` (`byReference == false`) / `R:n;` (`true`) — 1-based slot, see `phpSlotPath(_:)`.
    case reference(index: Int, byReference: Bool)
    /// PHP `C:` (custom `Serializable`) — payload shown raw.
    case custom(className: String, payload: String)

    public enum Key: Sendable, Hashable {
        case int(Int64)
        case string(String)

        public var text: String {
            switch self {
            case .int(let i): String(i)
            case .string(let s): s
            }
        }
    }

    public enum Visibility: Sendable, Hashable {
        case `public`
        case protected
        /// Private property declared in the given class.
        case `private`(String)
    }

    public struct Entry: Sendable, Equatable {
        public let key: Key
        public let value: StructuredValue
        public init(key: Key, value: StructuredValue) {
            self.key = key
            self.value = value
        }
    }

    public struct Property: Sendable, Equatable {
        public let name: String
        public let visibility: Visibility
        public let value: StructuredValue
        public init(name: String, visibility: Visibility = .public, value: StructuredValue) {
            self.name = name
            self.visibility = visibility
            self.value = value
        }
    }

    /// Uniform child view of arrays and objects.
    public struct Child: Sendable {
        public let key: Key
        /// `nil` for array entries.
        public let visibility: Visibility?
        public let value: StructuredValue
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    public var childCount: Int {
        switch self {
        case .array(let e): e.count
        case .object(_, let p): p.count
        default: 0
        }
    }

    public func child(at index: Int) -> Child {
        switch self {
        case .array(let e):
            Child(key: e[index].key, visibility: nil, value: e[index].value)
        case .object(_, let p):
            Child(key: .string(p[index].name), visibility: p[index].visibility, value: p[index].value)
        default:
            preconditionFailure("child(at:) on a scalar")
        }
    }

    /// Node at an index path (child indices from this node), `nil` when out of range.
    public func node(at path: [Int]) -> StructuredValue? {
        var node = self
        for i in path {
            guard node.isContainer, i >= 0, i < node.childCount else { return nil }
            node = node.child(at: i).value
        }
        return node
    }

    /// One-line text of a scalar (strings unquoted); containers give an empty string.
    public var scalarText: String {
        switch self {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let d): Self.format(d)
        case .string(let s): s
        case .enumCase(let c, let n): "\(c)::\(n)"
        case .reference(let i, _): "→ ref #\(i)"
        case .custom(_, let payload): payload
        case .array, .object: ""
        }
    }

    /// Value for "Kopírovať hodnotu": scalars as text, containers as `prettyText()`.
    public var copyText: String { isContainer ? prettyText() : scalarText }

    static func format(_ d: Double) -> String {
        if d.isNaN { return "NAN" }
        if d.isInfinite { return d < 0 ? "-INF" : "INF" }
        return d.description
    }

    // MARK: Paths

    /// Appends a key to a copyable access path: `data.page.title`, `items[3]`, `map["a.b"]`.
    public static func appendPath(_ base: String, _ key: Key) -> String {
        switch key {
        case .int(let i):
            return base + "[\(i)]"
        case .string(let s):
            if s.wholeMatch(of: /[A-Za-z_$][A-Za-z0-9_$]*/) != nil {
                return base.isEmpty ? s : base + "." + s
            }
            return base + "[" + quoted(s) + "]"
        }
    }

    /// Access path of the node at an index path.
    public func path(of indexPath: [Int]) -> String {
        var node = self
        var out = ""
        for i in indexPath {
            guard node.isContainer, i < node.childCount else { break }
            let c = node.child(at: i)
            out = Self.appendPath(out, c.key)
            node = c.value
        }
        return out
    }

    /// PHP reference slots (`r:n` / `R:n`, 1-based): every value in document order occupies a slot,
    /// except `R:` references themselves; array keys don't. Returns the index path of slot `n`.
    public func phpSlotPath(_ n: Int) -> [Int]? {
        guard n >= 1 else { return nil }
        var counter = 0
        var found: [Int]?
        preOrder { v, _, path in
            if case .reference(_, true) = v { return true }
            counter += 1
            if counter == n { found = path; return false }
            return true
        }
        return found
    }

    /// Iterative (stack-safe) pre-order walk; `visit(node, key, indexPath)` returns false to stop.
    public func preOrder(_ visit: (StructuredValue, Key?, [Int]) -> Bool) {
        guard visit(self, nil, []) else { return }
        var frames: [(value: StructuredValue, next: Int)] = [(self, 0)]
        var path: [Int] = []
        while let top = frames.last {
            guard top.next < top.value.childCount else {
                frames.removeLast()
                if !path.isEmpty { path.removeLast() }
                continue
            }
            let i = top.next
            frames[frames.count - 1].next += 1
            let c = top.value.child(at: i)
            path.append(i)
            guard visit(c.value, c.key, path) else { return }
            if c.value.childCount > 0 {
                frames.append((c.value, 0))
            } else {
                path.removeLast()
            }
        }
    }

    // MARK: Search

    /// Index paths of nodes whose key, class name or scalar value contains `query`
    /// (case- and diacritic-insensitive), in document order, at most `limit`.
    /// Checks `Task.isCancelled` periodically and returns what it has when cancelled.
    public func search(_ query: String, limit: Int = 5000) -> [[Int]] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result: [[Int]] = []
        var visited = 0
        func contains(_ s: String) -> Bool {
            s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        preOrder { v, key, path in
            visited += 1
            if visited & 0x3FF == 0, Task.isCancelled { return false }
            var hit = false
            if case .string(let k)? = key, contains(k) { hit = true }
            if !hit {
                switch v {
                case .array: break
                case .object(let c, _): hit = c.map(contains) ?? false
                case .custom(let c, let payload): hit = contains(c) || contains(payload)
                default: hit = contains(v.scalarText)
                }
            }
            if hit {
                result.append(path)
                if result.count >= limit { return false }
            }
            return true
        }
        return result
    }

    // MARK: Pretty text

    /// Indented JSON-like text. PHP objects get an `"@class"` line, non-public properties a
    /// `" (protected)"` / `" (private Class)"` suffix; references / enums render as strings.
    public func prettyText(indent: String = "  ") -> String {
        let value = self
        return withLargeStack { () -> String in
            var out = ""
            value.write(to: &out, level: 0, indent: indent)
            return out
        }
    }

    private func write(to out: inout String, level: Int, indent: String) {
        func nl(_ l: Int) {
            out.append("\n")
            for _ in 0..<l { out.append(indent) }
        }
        switch self {
        case .null, .bool, .int:
            out.append(scalarText)
        case .double(let d):
            out.append(Self.format(d))
        case .string(let s):
            out.append(Self.quoted(s))
        case .enumCase, .reference:
            out.append(Self.quoted(scalarText))
        case .custom(let c, let payload):
            out.append("{")
            nl(level + 1)
            out.append("\"@class\": " + Self.quoted(c) + ",")
            nl(level + 1)
            out.append("\"@serialized\": " + Self.quoted(payload))
            nl(level)
            out.append("}")
        case .array(let entries):
            // A PHP list (keys 0…n-1) renders as a JSON array, anything else as an object.
            let isList = entries.enumerated().allSatisfy { $0.element.key == .int(Int64($0.offset)) }
            if entries.isEmpty {
                out.append("[]")
                return
            }
            out.append(isList ? "[" : "{")
            for (i, e) in entries.enumerated() {
                nl(level + 1)
                if !isList {
                    out.append(Self.quoted(e.key.text) + ": ")
                }
                e.value.write(to: &out, level: level + 1, indent: indent)
                if i < entries.count - 1 { out.append(",") }
            }
            nl(level)
            out.append(isList ? "]" : "}")
        case .object(let className, let props):
            if props.isEmpty && className == nil {
                out.append("{}")
                return
            }
            out.append("{")
            var first = true
            if let className {
                nl(level + 1)
                out.append("\"@class\": " + Self.quoted(className))
                first = false
            }
            for p in props {
                if !first { out.append(",") }
                first = false
                nl(level + 1)
                let name = switch p.visibility {
                case .public: p.name
                case .protected: p.name + " (protected)"
                case .private(let c): p.name + " (private \(c))"
                }
                out.append(Self.quoted(name) + ": ")
                p.value.write(to: &out, level: level + 1, indent: indent)
            }
            nl(level)
            out.append("}")
        }
    }

    /// JSON string literal.
    public static func quoted(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case _ where u.value < 0x20:
                let h = String(u.value, radix: 16)
                out.append("\\u" + String(repeating: "0", count: 4 - h.count) + h)
            default: out.unicodeScalars.append(u)
            }
        }
        out.append("\"")
        return out
    }
}

/// Malformed input, with the byte offset where parsing stopped.
public struct StructuredParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let offset: Int
    public let message: String
    public init(offset: Int, message: String) {
        self.offset = offset
        self.message = message
    }
    public var description: String { "\(message) at byte \(offset)" }
}

// MARK: - Byte cursor shared by both parsers

/// Recursive-descent parsing of deeply nested input needs more than a secondary thread's 512 KB
/// (cooperative pool / test runner), so it runs on a dedicated thread with a 64 MB stack.
private final class LargeStackBox<T, E: Error>: @unchecked Sendable {
    var result: Result<T, E>?
}

func withLargeStack<T: Sendable, E: Error>(
    _ body: @escaping @Sendable () throws(E) -> T
) throws(E) -> T {
    let box = LargeStackBox<T, E>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.result = Result { () throws(E) in try body() }
        done.signal()
    }
    thread.stackSize = 64 << 20
    thread.start()
    done.wait()
    return try box.result!.get()
}

private struct ByteCursor {
    let bytes: [UInt8]
    var pos = 0
    var depth = 0
    static let maxDepth = 256

    init(_ data: Data) { bytes = Array(data) }

    var atEnd: Bool { pos >= bytes.count }
    var current: UInt8? { pos < bytes.count ? bytes[pos] : nil }

    func fail(_ message: String, at offset: Int? = nil) -> StructuredParseError {
        StructuredParseError(offset: offset ?? pos, message: message)
    }

    mutating func expect(_ b: UInt8) throws(StructuredParseError) {
        guard current == b else {
            throw fail("expected '\(Character(UnicodeScalar(b)))'" + (current.map { ", found '\(Character(UnicodeScalar($0)))'" } ?? ", found end of input"))
        }
        pos += 1
    }

    mutating func expect(_ s: String) throws(StructuredParseError) {
        for b in s.utf8 { try expect(b) }
    }

    mutating func skipWhitespace() {
        while let c = current, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { pos += 1 }
    }

    mutating func enter() throws(StructuredParseError) {
        depth += 1
        if depth > Self.maxDepth { throw fail("nesting deeper than \(Self.maxDepth)") }
    }

    func string(_ range: Range<Int>) -> String {
        let slice = bytes[range]
        return String(validating: slice, as: UTF8.self) ?? String(decoding: slice, as: UTF8.self)
    }
}

// MARK: - PHP serialize()

/// Pure-Swift reader of PHP `serialize()` output. Never instantiates or executes anything:
/// objects become `.object(className:properties:)` data.
public enum PHPSerializedParser {
    public static func parse(_ text: String) throws(StructuredParseError) -> StructuredValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws(StructuredParseError) -> StructuredValue {
        try withLargeStack { () throws(StructuredParseError) in try parseDocument(data) }
    }

    private static func parseDocument(_ data: Data) throws(StructuredParseError) -> StructuredValue {
        var c = ByteCursor(data)
        c.skipWhitespace()
        let value = try parseValue(&c)
        c.skipWhitespace()
        guard c.atEnd else { throw c.fail("unexpected data after value") }
        return value
    }

    private static func parseValue(_ c: inout ByteCursor) throws(StructuredParseError) -> StructuredValue {
        guard let t = c.current else { throw c.fail("unexpected end of input") }
        let start = c.pos
        switch t {
        case UInt8(ascii: "N"):
            try c.expect("N;")
            return .null
        case UInt8(ascii: "b"):
            try c.expect("b:")
            let v = c.current
            guard v == UInt8(ascii: "0") || v == UInt8(ascii: "1") else { throw c.fail("boolean must be 0 or 1") }
            c.pos += 1
            try c.expect(UInt8(ascii: ";"))
            return .bool(v == UInt8(ascii: "1"))
        case UInt8(ascii: "i"):
            try c.expect("i:")
            let v = try readInt(&c)
            try c.expect(UInt8(ascii: ";"))
            return .int(v)
        case UInt8(ascii: "d"):
            try c.expect("d:")
            let s = c.pos
            while let b = c.current, b != UInt8(ascii: ";") { c.pos += 1 }
            let text = c.string(s..<c.pos)
            let value: Double? = switch text {
            case "INF": .infinity
            case "-INF": -.infinity
            case "NAN": .nan
            default: text.wholeMatch(of: /[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?/) != nil ? Double(text) : nil
            }
            guard let value else { throw c.fail("invalid float '\(text)'", at: s) }
            try c.expect(UInt8(ascii: ";"))
            return .double(value)
        case UInt8(ascii: "s"):
            try c.expect("s:")
            let s = try readQuoted(&c)
            try c.expect(UInt8(ascii: ";"))
            return .string(s)
        case UInt8(ascii: "a"):
            try c.expect("a:")
            let n = try readCount(&c)
            try c.expect(":{")
            try c.enter()
            var entries: [StructuredValue.Entry] = []
            entries.reserveCapacity(min(n, 1 << 16))
            for _ in 0..<n {
                let key = try parseKey(&c)
                entries.append(.init(key: key, value: try parseValue(&c)))
            }
            c.depth -= 1
            try c.expect(UInt8(ascii: "}"))
            return .array(entries)
        case UInt8(ascii: "O"):
            try c.expect("O:")
            let className = try readQuoted(&c)
            try c.expect(UInt8(ascii: ":"))
            let n = try readCount(&c)
            try c.expect(":{")
            try c.enter()
            var props: [StructuredValue.Property] = []
            props.reserveCapacity(min(n, 1 << 16))
            for _ in 0..<n {
                let key = try parseKey(&c)
                let (name, vis) = demangle(key)
                props.append(.init(name: name, visibility: vis, value: try parseValue(&c)))
            }
            c.depth -= 1
            try c.expect(UInt8(ascii: "}"))
            return .object(className: className, properties: props)
        case UInt8(ascii: "C"):
            try c.expect("C:")
            let className = try readQuoted(&c)
            try c.expect(UInt8(ascii: ":"))
            let len = try readCount(&c)
            try c.expect(":{")
            guard c.pos + len <= c.bytes.count else { throw c.fail("payload length \(len) exceeds input", at: start) }
            let payload = c.string(c.pos..<(c.pos + len))
            c.pos += len
            try c.expect(UInt8(ascii: "}"))
            return .custom(className: className, payload: payload)
        case UInt8(ascii: "E"):
            try c.expect("E:")
            let s = try readQuoted(&c)
            try c.expect(UInt8(ascii: ";"))
            guard let colon = s.firstIndex(of: ":") else { throw c.fail("enum value without ':'", at: start) }
            return .enumCase(className: String(s[..<colon]), caseName: String(s[s.index(after: colon)...]))
        case UInt8(ascii: "r"), UInt8(ascii: "R"):
            c.pos += 1
            try c.expect(UInt8(ascii: ":"))
            let n = try readCount(&c)
            try c.expect(UInt8(ascii: ";"))
            return .reference(index: n, byReference: t == UInt8(ascii: "R"))
        default:
            throw c.fail("unexpected '\(Character(UnicodeScalar(t)))'")
        }
    }

    private static func parseKey(_ c: inout ByteCursor) throws(StructuredParseError) -> StructuredValue.Key {
        switch c.current {
        case UInt8(ascii: "i"):
            try c.expect("i:")
            let v = try readInt(&c)
            try c.expect(UInt8(ascii: ";"))
            return .int(v)
        case UInt8(ascii: "s"):
            try c.expect("s:")
            let s = try readQuoted(&c)
            try c.expect(UInt8(ascii: ";"))
            return .string(s)
        default:
            throw c.fail("array key must be int or string")
        }
    }

    /// `\0*\0name` → protected, `\0Class\0name` → private, otherwise public.
    static func demangle(_ key: StructuredValue.Key) -> (String, StructuredValue.Visibility) {
        guard case .string(let s) = key else { return (key.text, .public) }
        guard s.hasPrefix("\0") else { return (s, .public) }
        let rest = s.dropFirst()
        guard let nul = rest.firstIndex(of: "\0") else { return (s, .public) }
        let owner = String(rest[..<nul])
        let name = String(rest[rest.index(after: nul)...])
        return owner == "*" ? (name, .protected) : (name, .private(owner))
    }

    private static func readInt(_ c: inout ByteCursor) throws(StructuredParseError) -> Int64 {
        let s = c.pos
        if c.current == UInt8(ascii: "-") || c.current == UInt8(ascii: "+") { c.pos += 1 }
        let digitsStart = c.pos
        while let b = c.current, (0x30...0x39).contains(b) { c.pos += 1 }
        guard c.pos > digitsStart else { throw c.fail("expected integer") }
        guard let v = Int64(c.string(s..<c.pos)) else { throw c.fail("integer out of range", at: s) }
        return v
    }

    private static func readCount(_ c: inout ByteCursor) throws(StructuredParseError) -> Int {
        let s = c.pos
        while let b = c.current, (0x30...0x39).contains(b) { c.pos += 1 }
        guard c.pos > s else { throw c.fail("expected length") }
        guard c.pos - s <= 12, let v = Int(c.string(s..<c.pos)) else { throw c.fail("length out of range", at: s) }
        return v
    }

    /// `<byte-len>:"<bytes>"` — the length counts UTF-8 bytes, not characters.
    private static func readQuoted(_ c: inout ByteCursor) throws(StructuredParseError) -> String {
        let start = c.pos
        let len = try readCount(&c)
        try c.expect(":\"")
        let end = c.pos + len
        guard end < c.bytes.count, c.bytes[end] == UInt8(ascii: "\"") else {
            throw c.fail("string length \(len) does not match data", at: start)
        }
        let s = c.string(c.pos..<end)
        c.pos = end + 1
        return s
    }
}

// MARK: - Order-preserving JSON

/// Strict RFC 8259 JSON reader that keeps object key order (JSONSerialization does not).
/// Top-level scalars are allowed. Integers that fit Int64 stay `.int`, other numbers `.double`.
public enum OrderedJSONParser {
    public static func parse(_ text: String) throws(StructuredParseError) -> StructuredValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws(StructuredParseError) -> StructuredValue {
        try withLargeStack { () throws(StructuredParseError) in try parseDocument(data) }
    }

    private static func parseDocument(_ data: Data) throws(StructuredParseError) -> StructuredValue {
        var c = ByteCursor(data)
        c.skipWhitespace()
        let v = try parseValue(&c)
        c.skipWhitespace()
        guard c.atEnd else { throw c.fail("unexpected data after value") }
        return v
    }

    private static func parseValue(_ c: inout ByteCursor) throws(StructuredParseError) -> StructuredValue {
        guard let t = c.current else { throw c.fail("unexpected end of input") }
        switch t {
        case UInt8(ascii: "{"):
            c.pos += 1
            try c.enter()
            var props: [StructuredValue.Property] = []
            c.skipWhitespace()
            if c.current == UInt8(ascii: "}") {
                c.pos += 1
            } else {
                while true {
                    c.skipWhitespace()
                    guard c.current == UInt8(ascii: "\"") else { throw c.fail("expected object key") }
                    let key = try parseString(&c)
                    c.skipWhitespace()
                    try c.expect(UInt8(ascii: ":"))
                    c.skipWhitespace()
                    props.append(.init(name: key, value: try parseValue(&c)))
                    c.skipWhitespace()
                    if c.current == UInt8(ascii: ",") { c.pos += 1; continue }
                    try c.expect(UInt8(ascii: "}"))
                    break
                }
            }
            c.depth -= 1
            return .object(className: nil, properties: props)
        case UInt8(ascii: "["):
            c.pos += 1
            try c.enter()
            var items: [StructuredValue.Entry] = []
            c.skipWhitespace()
            if c.current == UInt8(ascii: "]") {
                c.pos += 1
            } else {
                while true {
                    c.skipWhitespace()
                    items.append(.init(key: .int(Int64(items.count)), value: try parseValue(&c)))
                    c.skipWhitespace()
                    if c.current == UInt8(ascii: ",") { c.pos += 1; continue }
                    try c.expect(UInt8(ascii: "]"))
                    break
                }
            }
            c.depth -= 1
            return .array(items)
        case UInt8(ascii: "\""):
            return .string(try parseString(&c))
        case UInt8(ascii: "t"):
            try c.expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try c.expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try c.expect("null")
            return .null
        case UInt8(ascii: "-"), 0x30...0x39:
            return try parseNumber(&c)
        default:
            throw c.fail("unexpected '\(Character(UnicodeScalar(t)))'")
        }
    }

    private static func parseNumber(_ c: inout ByteCursor) throws(StructuredParseError) -> StructuredValue {
        let s = c.pos
        func digits(_ c: inout ByteCursor) -> Int {
            let d = c.pos
            while let b = c.current, (0x30...0x39).contains(b) { c.pos += 1 }
            return c.pos - d
        }
        if c.current == UInt8(ascii: "-") { c.pos += 1 }
        let intStart = c.pos
        let n = digits(&c)
        guard n > 0 else { throw c.fail("invalid number", at: s) }
        if n > 1, c.bytes[intStart] == UInt8(ascii: "0") { throw c.fail("leading zero in number", at: s) }
        var isInt = true
        if c.current == UInt8(ascii: ".") {
            c.pos += 1
            isInt = false
            guard digits(&c) > 0 else { throw c.fail("invalid number", at: s) }
        }
        if c.current == UInt8(ascii: "e") || c.current == UInt8(ascii: "E") {
            c.pos += 1
            isInt = false
            if c.current == UInt8(ascii: "+") || c.current == UInt8(ascii: "-") { c.pos += 1 }
            guard digits(&c) > 0 else { throw c.fail("invalid number", at: s) }
        }
        let text = c.string(s..<c.pos)
        if isInt, let i = Int64(text) { return .int(i) }
        guard let d = Double(text) else { throw c.fail("invalid number", at: s) }
        return .double(d)
    }

    private static func parseString(_ c: inout ByteCursor) throws(StructuredParseError) -> String {
        let start = c.pos
        try c.expect(UInt8(ascii: "\""))
        var out: [UInt8] = []
        func appendScalar(_ v: UInt32) {
            let scalar = UnicodeScalar(v) ?? "\u{FFFD}"
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        }
        func hex4(_ c: inout ByteCursor) throws(StructuredParseError) -> UInt32 {
            guard c.pos + 4 <= c.bytes.count else { throw c.fail("truncated \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let b = c.bytes[c.pos]
                let d: UInt32
                switch b {
                case 0x30...0x39: d = UInt32(b - 0x30)
                case 0x41...0x46: d = UInt32(b - 0x41 + 10)
                case 0x61...0x66: d = UInt32(b - 0x61 + 10)
                default: throw c.fail("invalid \\u escape")
                }
                v = v << 4 | d
                c.pos += 1
            }
            return v
        }
        while true {
            guard let b = c.current else { throw c.fail("unterminated string", at: start) }
            switch b {
            case UInt8(ascii: "\""):
                c.pos += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                c.pos += 1
                guard let e = c.current else { throw c.fail("unterminated string", at: start) }
                c.pos += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let hi = try hex4(&c)
                    if (0xD800...0xDBFF).contains(hi), c.current == 0x5C,
                       c.pos + 1 < c.bytes.count, c.bytes[c.pos + 1] == UInt8(ascii: "u") {
                        let save = c.pos
                        c.pos += 2
                        let lo = try hex4(&c)
                        if (0xDC00...0xDFFF).contains(lo) {
                            appendScalar(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00))
                        } else {
                            appendScalar(0xFFFD)
                            c.pos = save
                        }
                    } else {
                        appendScalar(hi)
                    }
                default:
                    throw c.fail("invalid escape", at: c.pos - 2)
                }
            case 0x00..<0x20:
                throw c.fail("control character in string")
            default:
                out.append(b)
                c.pos += 1
            }
        }
    }
}

extension RedisValueFormat {
    /// Structured tree of a JSON (object/array) or PHP-serialized value; `nil` for other kinds.
    public static func structured(_ data: Data, kind: RedisValueKind) throws(StructuredParseError) -> StructuredValue? {
        switch kind {
        case .json: try OrderedJSONParser.parse(data)
        case .phpSerialized: try PHPSerializedParser.parse(data)
        case .text, .binary: nil
        }
    }
}
