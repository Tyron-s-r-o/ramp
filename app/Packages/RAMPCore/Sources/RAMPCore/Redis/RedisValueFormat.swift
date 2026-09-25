import Foundation

/// How a Redis string value is shown in the browser.
public enum RedisValueKind: String, Sendable, Equatable {
    case json
    case phpSerialized
    case text
    case binary
}

/// Display helpers for binary-safe Redis values: UTF-8 text with hex fallback, JSON / PHP-serialize
/// detection, order-preserving JSON pretty print + token spans for syntax colouring.
public enum RedisValueFormat {
    /// Values above this are truncated in the UI (first `previewBytes` shown + "Zobraziť celé").
    public static let largeValueBytes = 1024 * 1024
    public static let previewBytes = 64 * 1024

    /// Valid UTF-8 without NUL / other C0 controls (except tab, CR, LF, ESC-free) → text.
    public static func isText(_ data: Data) -> Bool {
        guard String(validating: data, as: UTF8.self) != nil else { return false }
        for b in data where b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D {
            return false
        }
        return !data.contains(0x7F)
    }

    /// Text if UTF-8, otherwise lowercase hex (`\xNN` style would be ambiguous in keys, so plain hex).
    public static func display(_ data: Data) -> String {
        if isText(data), let s = String(validating: data, as: UTF8.self) { return s }
        return "0x" + hex(data)
    }

    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Classic 16-bytes-per-line dump: `00000000  48 65 6c 6c 6f …  |Hello…|`.
    public static func hexDump(_ data: Data, limit: Int = previewBytes) -> String {
        let bytes = Array(data.prefix(limit))
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var hexPart = row.map { b -> String in
                let h = String(b, radix: 16)
                return h.count == 1 ? "0" + h : h
            }.joined(separator: " ")
            hexPart += String(repeating: " ", count: max(0, 47 - hexPart.count))
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            let off = String(offset, radix: 16)
            lines.append(String(repeating: "0", count: max(0, 8 - off.count)) + off + "  " + hexPart + "  |" + ascii + "|")
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    public static func kind(_ data: Data) -> RedisValueKind {
        guard isText(data), let s = String(validating: data, as: UTF8.self) else { return .binary }
        if isPHPSerialized(s) { return .phpSerialized }
        if isJSON(data, text: s) { return .json }
        return .text
    }

    /// Object / array JSON only (bare numbers and strings stay plain text).
    public static func isJSON(_ data: Data, text: String? = nil) -> Bool {
        let s = text ?? String(decoding: data, as: UTF8.self)
        guard let first = s.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// PHP `serialize()` output: arrays `a:N:{`, objects `O:N:"`, custom `C:N:"`, strings `s:N:"`,
    /// and whole-value scalars `i:N;`, `d:N;`, `b:0;`, `N;`.
    public static func isPHPSerialized(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "N;" { return true }
        if t.wholeMatch(of: /b:[01];/) != nil { return true }
        if t.wholeMatch(of: /i:-?\d+;/) != nil { return true }
        if t.wholeMatch(of: /d:-?(\d+(\.\d*)?([eE][-+]?\d+)?|INF|NAN);/) != nil { return true }
        if t.prefixMatch(of: /a:\d+:\{/) != nil, t.hasSuffix("}") { return true }
        if t.prefixMatch(of: /[OC]:\d+:"/) != nil, t.hasSuffix("}") { return true }
        if t.prefixMatch(of: /s:\d+:"/) != nil, t.hasSuffix("\";") { return true }
        return false
    }

    // MARK: JSON pretty print (keeps key order, unlike JSONSerialization)

    /// Re-indents valid JSON with 2 spaces. Invalid input is returned unchanged.
    public static func prettyJSON(_ text: String, indent: String = "  ") -> String {
        guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
        else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var level = 0
        var inString = false
        var escaped = false
        let chars = Array(text)
        var i = 0
        func newline() {
            out.append("\n")
            out.append(String(repeating: indent, count: level))
        }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Empty container stays on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(chars[j])
                    i = j
                } else {
                    out.append(c)
                    level += 1
                    newline()
                }
            case "}", "]":
                level = max(0, level - 1)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(": ")
            case _ where c.isWhitespace:
                break
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }

    public enum JSONToken: Sendable, Equatable {
        case key, string, number, literal, punctuation
    }

    /// Token spans (UTF-16 offsets, for NSRange / AttributedString) of a JSON text; whitespace skipped.
    public static func jsonTokens(_ text: String) -> [(kind: JSONToken, range: Range<Int>)] {
        let u = Array(text.utf16)
        var result: [(kind: JSONToken, range: Range<Int>)] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            switch c {
            case 0x22: // "
                let start = i
                i += 1
                while i < u.count {
                    if u[i] == 0x5C { i += 2; continue }
                    if u[i] == 0x22 { i += 1; break }
                    i += 1
                }
                i = min(i, u.count)
                // A string followed (after whitespace) by ':' is an object key.
                var j = i
                while j < u.count, u[j] == 0x20 || u[j] == 0x0A || u[j] == 0x0D || u[j] == 0x09 { j += 1 }
                let isKey = j < u.count && u[j] == 0x3A
                result.append((isKey ? .key : .string, start..<i))
            case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C:
                result.append((.punctuation, i..<(i + 1)))
                i += 1
            case 0x2D, 0x30...0x39:
                let start = i
                i += 1
                while i < u.count, let s = UnicodeScalar(u[i]), "0123456789.eE+-".unicodeScalars.contains(s) { i += 1 }
                result.append((.number, start..<i))
            case 0x74, 0x66, 0x6E: // true / false / null
                let start = i
                while i < u.count, (0x61...0x7A).contains(u[i]) { i += 1 }
                result.append((.literal, start..<i))
            default:
                i += 1
            }
        }
        return result
    }
}
