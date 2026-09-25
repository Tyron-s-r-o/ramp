import Darwin
import Foundation
import RAMPHostsKit

// MARK: - Filesystem access (read-only metadata)

public enum FileKind: Sendable, Equatable {
    case directory, file, missing
}

/// The only filesystem access the validator needs. RAMP never writes into project folders.
public protocol FileChecking: Sendable {
    /// Kind of the item at `path`, following symlinks.
    func kind(at path: String) -> FileKind
    /// Canonical absolute path with all symlinks resolved; `nil` when the path does not exist.
    func realpath(_ path: String) -> String?
}

public struct LiveFileChecking: FileChecking {
    public init() {}

    public func kind(at path: String) -> FileKind {
        guard let resolved = realpath(path) else { return .missing }
        var st = stat()
        guard lstat(resolved, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        default: return .file
        }
    }

    public func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Issues

public struct VhostIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Field: String, Sendable, Equatable { case domain, alias, docroot, php, group, limits }
    public enum Severity: String, Sendable, Equatable { case error, warning }

    /// `nil` = config-wide issue (limits).
    public var vhostID: UUID?
    public var field: Field
    public var severity: Severity
    public var message: String

    public init(vhostID: UUID?, field: Field, severity: Severity, message: String) {
        self.vhostID = vhostID
        self.field = field
        self.severity = severity
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(message)" }
}

// MARK: - Validator

/// Pure validation of `config.vhosts`. Reads only filesystem metadata through `FileChecking`.
public struct VhostValidator: Sendable {
    public static let maxVhosts = 500
    /// Total hostnames of enabled vhosts — the hosts helper refuses more.
    public static let maxHostnames = Hostname.maxNames

    /// Resolved docroots must not equal or live inside these.
    static let forbiddenPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/etc", "/Library", "/Applications"]

    public let config: RampConfig
    public let paths: Paths
    public let fs: any FileChecking
    public let home: URL

    public init(config: RampConfig, paths: Paths, fs: any FileChecking = LiveFileChecking(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.config = config
        self.paths = paths
        self.fs = fs
        self.home = home
    }

    public func validate() -> [VhostIssue] {
        var issues: [VhostIssue] = []
        let vhosts = config.vhosts

        if vhosts.count > Self.maxVhosts {
            issues.append(VhostIssue(vhostID: nil, field: .limits, severity: .error,
                                     message: "Too many vhosts (\(vhosts.count)); the maximum is \(Self.maxVhosts)"))
        }
        let enabledNames = vhosts.filter(\.enabled).reduce(0) { $0 + $1.hostnames.count }
        if enabledNames > Self.maxHostnames {
            issues.append(VhostIssue(vhostID: nil, field: .limits, severity: .error,
                                     message: "Too many hostnames in enabled vhosts (\(enabledNames)); the maximum is \(Self.maxHostnames)"))
        }

        // hostname (lowercased) → index of the vhost that claimed it first
        var owner: [String: Int] = [:]
        owner.reserveCapacity(vhosts.count * 2)
        let forbidden = forbiddenRoots()
        let installedPHP = config.installed["php"] ?? [:]

        for (index, vhost) in vhosts.enumerated() {
            // Hostnames
            let names = [(vhost.domain, VhostIssue.Field.domain)] + vhost.aliases.map { ($0, VhostIssue.Field.alias) }
            for (name, field) in names {
                if let problem = hostnameProblem(name) {
                    issues.append(VhostIssue(vhostID: vhost.id, field: field, severity: .error,
                                             message: "\(field == .domain ? "Domain" : "Alias") \(problem)"))
                    continue
                }
                let key = name.lowercased()
                let label = field == .domain ? "Domain" : "Alias"
                if let other = owner[key] {
                    let message = other == index
                        ? "\(label) \(key) is listed more than once in vhost \(vhost.domain.lowercased())"
                        : "\(label) \(key) is already used by vhost \(vhosts[other].domain.lowercased())"
                    issues.append(VhostIssue(vhostID: vhost.id, field: field, severity: .error, message: message))
                } else {
                    owner[key] = index
                }
            }

            // Docroot
            issues.append(contentsOf: docrootIssues(vhost, forbidden: forbidden))

            // Group (UI folder)
            if let problem = Self.groupProblem(vhost.group) {
                issues.append(VhostIssue(vhostID: vhost.id, field: .group, severity: .error,
                                         message: "Group of \(vhost.domain) \(problem)"))
            }

            // PHP
            if let branch = vhost.phpBranch {
                if installedPHP[branch] == nil {
                    issues.append(VhostIssue(vhostID: vhost.id, field: .php, severity: .error,
                                             message: "PHP \(branch) for \(vhost.domain) is not installed"))
                } else if config.php.branches[branch]?.enabled == false {
                    issues.append(VhostIssue(vhostID: vhost.id, field: .php, severity: .error,
                                             message: "PHP \(branch) for \(vhost.domain) is disabled"))
                }
            } else if installedPHP.isEmpty {
                issues.append(VhostIssue(vhostID: vhost.id, field: .php, severity: .warning,
                                         message: "No PHP is installed; \(vhost.domain) will be served without PHP"))
            }
        }
        return issues
    }

    // MARK: helpers

    /// `nil` = valid (or no group). Otherwise the tail of a message ("is too long …").
    public static func groupProblem(_ group: String?) -> String? {
        guard let group else { return nil }
        if group.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                || $0.properties.generalCategory == .paragraphSeparator
        }) {
            return "must not contain line breaks or control characters"
        }
        if group.trimmingCharacters(in: .whitespaces).isEmpty { return "must not be empty" }
        if group.count > Vhost.maxGroupLength {
            return "is too long (\(group.count) characters); the maximum is \(Vhost.maxGroupLength)"
        }
        return nil
    }

    /// `nil` = valid. Otherwise the tail of a message ("x is reserved", "x is not a valid hostname: …").
    private func hostnameProblem(_ name: String) -> String? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return "\(lower) is reserved (RAMP's default site lives on localhost)"
        }
        do {
            _ = try Hostname.validate(name)
            return nil
        } catch HostsError.reservedName {
            return "\(lower) is reserved"
        } catch {
            let display = name.isEmpty ? "(empty)" : name.debugDescription
            return "\(display) is not a valid hostname: \(error.localizedDescription)"
        }
    }

    private func docrootIssues(_ vhost: Vhost, forbidden: [String]) -> [VhostIssue] {
        func issue(_ severity: VhostIssue.Severity, _ message: String) -> VhostIssue {
            VhostIssue(vhostID: vhost.id, field: .docroot, severity: severity, message: message)
        }
        let path = vhost.docroot
        let site = vhost.domain
        guard path.hasPrefix("/") else {
            return [issue(.error, "Docroot of \(site) must be an absolute path")]
        }
        if path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return [issue(.error, "Docroot of \(site) contains control characters")]
        }
        if path.split(separator: "/").contains("..") {
            return [issue(.error, "Docroot of \(site) must not contain '..'")]
        }

        let resolved = Self.stripTrailingSlash(fs.realpath(path) ?? path)
        if resolved == "/" || resolved == homePath {
            return [issue(.error, "Docroot of \(site) must not be \(resolved) itself; use a project folder")]
        }
        if let root = forbidden.first(where: { Self.isSameOrInside(resolved, $0) }) {
            return [issue(.error, "Docroot of \(site) must not be inside \(root)")]
        }

        let severity: VhostIssue.Severity = vhost.enabled ? .error : .warning
        switch fs.kind(at: path) {
        case .directory: return []
        case .missing: return [issue(severity, "Docroot \(path) of \(site) does not exist")]
        case .file: return [issue(severity, "Docroot \(path) of \(site) is not a directory")]
        }
    }

    /// Roots a docroot must not be (inside). `$HOME` and `/` are exact-match only (checked separately).
    private func forbiddenRoots() -> [String] {
        func canonical(_ url: URL) -> String {
            let p = Self.stripTrailingSlash(url.path(percentEncoded: false))
            return fs.realpath(p) ?? p
        }
        return Self.forbiddenPrefixes + [canonical(paths.root), canonical(paths.logs)]
    }

    private var homePath: String {
        let p = Self.stripTrailingSlash(home.path(percentEncoded: false))
        return fs.realpath(p) ?? p
    }

    static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func stripTrailingSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
