import Foundation

/// Errors of the hosts-file logic. Messages are shown in the GUI and returned verbatim by the root helper.
public enum HostsError: Error, Equatable, Sendable, LocalizedError {
    case invalidHostname(String)
    case reservedName(String)
    case tooManyNames(Int)
    case malformedBlock(String)
    case fileTooLarge
    case notRegularFile
    case io(String)
    case invalidTeamID(String)
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHostname(let name):
            "Invalid hostname \(String(reflecting: name)): use ASCII letters, digits and hyphens in at least two dot-separated labels (IDN as xn-- punycode)."
        case .reservedName(let name):
            "Hostname \(String(reflecting: name)) is reserved by the system and cannot be managed by RAMP."
        case .tooManyNames(let count):
            "Too many hostnames (\(count)); at most \(Hostname.maxNames) are allowed."
        case .malformedBlock(let reason):
            "The RAMP block in the hosts file is malformed (\(reason)). Fix or remove the '# RAMP BEGIN' / '# RAMP END' lines manually; RAMP will not guess."
        case .fileTooLarge:
            "The hosts file is larger than \(HostsBlock.maxFileSize) bytes; refusing to rewrite it."
        case .notRegularFile:
            "The hosts file is not a regular file (symlink or other type); refusing to rewrite it."
        case .io(let message):
            "Hosts file I/O error: \(message)"
        case .invalidTeamID(let team):
            "Invalid Team ID \(String(reflecting: team)) (expected 10 characters A-Z / 0-9)."
        case .invalidIdentifier(let identifier):
            "Invalid code-signing identifier \(String(reflecting: identifier))."
        }
    }
}

/// Hostname rules shared by the app, the osascript fallback and the privileged helper.
public enum Hostname {
    /// Upper bound of names in one RAMP block (guards the root helper against abuse).
    public static let maxNames = 2000
    public static let maxLabelLength = 63
    public static let maxTotalLength = 253

    /// Names owned by the system's default hosts entries.
    public static let reservedNames: Set<String> = [
        "localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback",
    ]

    /// Validates and normalizes a hostname: trims spaces/tabs, lowercases, strips one trailing dot.
    /// - Throws: `HostsError.invalidHostname(input)` or `HostsError.reservedName(normalized)`.
    public static func validate(_ input: String) throws -> String {
        var bytes = Array(input.utf8)
        while let first = bytes.first, first == 0x20 || first == 0x09 { bytes.removeFirst() }
        while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }

        // Charset: ASCII LDH + dots only (rejects control chars, spaces, '#', '_', '*', ':', non-ASCII, …).
        var lowered: [UInt8] = []
        lowered.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."):
                lowered.append(b)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                lowered.append(b + 32)
            default:
                throw HostsError.invalidHostname(input)
            }
        }
        let name = String(decoding: lowered, as: UTF8.self)

        if reservedNames.contains(name) || name.hasSuffix(".localhost") {
            throw HostsError.reservedName(name)
        }

        guard !lowered.isEmpty, lowered.count <= maxTotalLength else { throw HostsError.invalidHostname(input) }
        let labels = lowered.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2 else { throw HostsError.invalidHostname(input) }
        for label in labels {
            guard !label.isEmpty, label.count <= maxLabelLength,
                  label.first != UInt8(ascii: "-"), label.last != UInt8(ascii: "-")
            else { throw HostsError.invalidHostname(input) }
        }
        // All-numeric TLD (also rejects IPv4 literals).
        if let tld = labels.last, tld.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            throw HostsError.invalidHostname(input)
        }
        return name
    }
}
