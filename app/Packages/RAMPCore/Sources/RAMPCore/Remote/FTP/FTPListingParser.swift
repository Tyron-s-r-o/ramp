import Foundation

/// Pure parsers for FTP directory listings: RFC 3659 `MLSD` facts and the de-facto `LIST`
/// formats (Unix `ls -l`, DOS/IIS). Dates without a zone are interpreted as UTC.
public enum FTPListingParser {

    // MARK: MLSD

    /// Parses an `MLSD` reply body. `directory` is the absolute path that was listed.
    public static func parseMLSD(_ text: String, directory: String) -> [RemoteItem] {
        lines(text).compactMap { parseMLSDLine($0, directory: directory) }
    }

    /// One `fact=value;fact=value; name` line (also the body of an `MLST` reply).
    public static func parseMLSDLine(_ line: String, directory: String) -> RemoteItem? {
        let factsPart: Substring
        let name: String
        if let sep = line.range(of: "; ") {
            factsPart = line[..<sep.lowerBound]
            name = String(line[sep.upperBound...])
        } else if line.hasPrefix(" ") {
            factsPart = ""
            name = String(line.dropFirst())
        } else if let space = line.firstIndex(of: " ") {
            factsPart = line[..<space]
            name = String(line[line.index(after: space)...])
        } else {
            return nil
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
            guard let eq = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<eq].lowercased()] = String(fact[fact.index(after: eq)...])
        }

        let type = facts["type"]?.lowercased() ?? "file"
        let kind: RemoteItem.Kind
        switch type {
        case "cdir", "pdir": return nil
        case "dir": kind = .directory
        case "file": kind = .file
        default:
            // "OS.unix=symlink", "OS.unix=slink:/target", "OS.unix=slink" …
            kind = type.contains("link") ? .symlink : .file
        }
        let baseName = name.split(separator: "/").last.map(String.init) ?? name
        return RemoteItem(
            path: RemotePath.join(directory, baseName),
            name: baseName,
            kind: kind,
            size: facts["size"].flatMap { Int64($0) } ?? facts["sizd"].flatMap { Int64($0) },
            modified: facts["modify"].flatMap(parseMLSDTime),
            permissions: facts["unix.mode"].flatMap(permissionString(octal:)))
    }

    /// `YYYYMMDDHHMMSS[.sss]` in UTC.
    public static func parseMLSDTime(_ s: String) -> Date? {
        let main = s.split(separator: ".", maxSplits: 1)
        let digits = Array(main[0])
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func num(_ a: Int, _ b: Int) -> Int { Int(String(digits[a..<b]))! }
        var c = DateComponents()
        c.year = num(0, 4); c.month = num(4, 6); c.day = num(6, 8)
        c.hour = num(8, 10); c.minute = num(10, 12); c.second = num(12, 14)
        guard var date = utcCalendar.date(from: c) else { return nil }
        if main.count == 2, let frac = Double("0." + main[1]) { date += frac }
        return date
    }

    /// "0755" / "755" / "100644" → "rwxr-xr-x".
    public static func permissionString(octal: String) -> String? {
        guard let v = Int(octal, radix: 8) else { return nil }
        return permissionString(mode: v)
    }

    public static func permissionString(mode: Int) -> String {
        let chars: [Character] = ["r", "w", "x"]
        var s = ""
        for i in 0..<9 {
            let bit = 1 << (8 - i)
            s.append(mode & bit != 0 ? chars[i % 3] : "-")
        }
        return s
    }

    // MARK: LIST

    /// Parses a `LIST` reply body (Unix or DOS style, auto-detected per line).
    public static func parseLIST(_ text: String, directory: String, now: Date = Date()) -> [RemoteItem] {
        lines(text).compactMap { line in
            parseUnixLine(line, directory: directory, now: now) ?? parseDOSLine(line, directory: directory)
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `drwxr-xr-x 2 user group 4096 Jan 12 10:30 name` / `… Jan 12  2023 name` / `l… a -> b`.
    static func parseUnixLine(_ line: String, directory: String, now: Date) -> RemoteItem? {
        guard let first = line.first, "-dlbcps".contains(first), line.count > 10 else { return nil }
        let tokens = tokenize(line)
        guard tokens.count >= 6 else { return nil }

        // Find "<month> <day> <time|year>" — the owner/group columns vary between servers.
        var m = -1
        for i in 2..<(tokens.count - 2) where months.contains(tokens[i].text.lowercased())
            && Int(tokens[i + 1].text) != nil
            && (tokens[i + 2].text.contains(":") || Int(tokens[i + 2].text) != nil) {
            m = i
            break
        }
        guard m >= 3, let size = Int64(tokens[m - 1].text) ?? (first == "d" ? 0 : nil) else { return nil }

        let timeToken = tokens[m + 2]
        var rest = line[timeToken.range.upperBound...]
        guard rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.dropFirst()
        var name = String(rest)
        if first == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let kind: RemoteItem.Kind = first == "d" ? .directory : (first == "l" ? .symlink : .file)
        let perms = String(tokens[0].text.dropFirst().prefix(9))
        let date = unixDate(month: tokens[m].text, day: tokens[m + 1].text, timeOrYear: timeToken.text, now: now)
        return RemoteItem(path: RemotePath.join(directory, name), name: name, kind: kind,
                          size: kind == .directory ? nil : size, modified: date,
                          permissions: perms.count == 9 ? perms : nil)
    }

    static func unixDate(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        guard let mi = months.firstIndex(of: month.lowercased()), let d = Int(day) else { return nil }
        var c = DateComponents()
        c.month = mi + 1
        c.day = d
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let mm = Int(hm[1]) else { return nil }
            c.hour = h
            c.minute = mm
            c.year = utcCalendar.component(.year, from: now)
            // "MMM dd HH:mm" means "within the last ~6 months": a future date is last year's.
            if let date = utcCalendar.date(from: c), date > now.addingTimeInterval(86_400) {
                c.year! -= 1
            }
        } else {
            guard let y = Int(timeOrYear) else { return nil }
            c.year = y
        }
        return utcCalendar.date(from: c)
    }

    /// IIS / DOS: `01-15-24  10:30AM       <DIR>          name` or `…  1234 name`.
    static func parseDOSLine(_ line: String, directory: String) -> RemoteItem? {
        let tokens = tokenize(line)
        guard tokens.count >= 4 else { return nil }
        let dateParts = tokens[0].text.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }
        var timeText = tokens[1].text.uppercased()
        var next = 2
        var pm = false, am = false
        if timeText.hasSuffix("AM") || timeText.hasSuffix("PM") {
            pm = timeText.hasSuffix("PM"); am = !pm
            timeText.removeLast(2)
        } else if tokens[2].text.uppercased() == "AM" || tokens[2].text.uppercased() == "PM" {
            pm = tokens[2].text.uppercased() == "PM"; am = !pm
            next = 3
        }
        let hm = timeText.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2, tokens.count > next + 1 else { return nil }

        let sizeToken = tokens[next]
        let isDir = sizeToken.text.uppercased() == "<DIR>"
        guard isDir || Int64(sizeToken.text) != nil else { return nil }
        var rest = line[sizeToken.range.upperBound...]
        while rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        let name = String(rest)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var hour = hm[0]
        if pm && hour < 12 { hour += 12 }
        if am && hour == 12 { hour = 0 }
        var year = dateParts[2]
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        var c = DateComponents()
        c.year = year; c.month = dateParts[0]; c.day = dateParts[1]; c.hour = hour; c.minute = hm[1]
        return RemoteItem(path: RemotePath.join(directory, name), name: name,
                          kind: isDir ? .directory : .file,
                          size: isDir ? nil : Int64(sizeToken.text),
                          modified: utcCalendar.date(from: c))
    }

    // MARK: PWD

    /// `257 "/home/u ""quoted"" dir" is current directory` → `/home/u "quoted" dir`.
    public static func parsePWDReply(_ reply: String) -> String? {
        guard let open = reply.firstIndex(of: "\"") else { return nil }
        var out = ""
        var i = reply.index(after: open)
        while i < reply.endIndex {
            let ch = reply[i]
            if ch == "\"" {
                let n = reply.index(after: i)
                if n < reply.endIndex, reply[n] == "\"" {
                    out.append("\"")
                    i = reply.index(after: n)
                    continue
                }
                return out
            }
            out.append(ch)
            i = reply.index(after: i)
        }
        return nil
    }

    // MARK: Helpers

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("total ") }
    }

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    private static func tokenize(_ line: String) -> [Token] {
        var out: [Token] = []
        var i = line.startIndex
        while i < line.endIndex {
            while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
            guard i < line.endIndex else { break }
            let start = i
            while i < line.endIndex, line[i] != " ", line[i] != "\t" { i = line.index(after: i) }
            out.append(Token(text: String(line[start..<i]), range: start..<i))
        }
        return out
    }
}
