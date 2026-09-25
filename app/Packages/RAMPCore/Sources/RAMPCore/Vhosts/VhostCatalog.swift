import Foundation

/// Thrown when a catalog operation would leave `ramp.json` with an invalid vhost state.
public struct VhostValidationError: Error, Equatable, LocalizedError {
    public let issues: [VhostIssue]

    public init(issues: [VhostIssue]) { self.issues = issues }

    public var errorDescription: String? { issues.map(\.message).joined(separator: "\n") }
}

public enum VhostCatalogError: Error, Equatable, LocalizedError {
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Vhost \(id.uuidString) does not exist"
        }
    }
}

/// Pure CRUD over `RampConfig.vhosts`. Every mutation is normalized and validated before it is
/// returned; nothing is written anywhere — the caller persists the returned config.
public struct VhostCatalog: Sendable {
    public struct Result: Sendable, Equatable {
        public var config: RampConfig
        /// Non-blocking issues of the touched vhost (and config-wide ones).
        public var warnings: [VhostIssue]
    }

    public let paths: Paths
    public let fs: any FileChecking
    public let home: URL

    public init(paths: Paths, fs: any FileChecking = LiveFileChecking(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.paths = paths
        self.fs = fs
        self.home = home
    }

    public func add(_ vhost: Vhost, in config: RampConfig) throws -> Result {
        var v = Self.normalized(vhost, tld: config.hosts.defaultTLD)
        let existing = Set(config.vhosts.map(\.id))
        while existing.contains(v.id) { v.id = UUID() }
        var next = config
        next.vhosts.append(v)
        return try commit(next, from: config, touched: v.id)
    }

    public func update(_ vhost: Vhost, in config: RampConfig) throws -> Result {
        guard let index = config.vhosts.firstIndex(where: { $0.id == vhost.id }) else {
            throw VhostCatalogError.notFound(vhost.id)
        }
        var next = config
        next.vhosts[index] = Self.normalized(vhost, tld: config.hosts.defaultTLD)
        return try commit(next, from: config, touched: vhost.id)
    }

    /// Removing can never introduce an invalid state, so it is not validated.
    public func remove(id: UUID, in config: RampConfig) throws -> Result {
        guard let index = config.vhosts.firstIndex(where: { $0.id == id }) else {
            throw VhostCatalogError.notFound(id)
        }
        var next = config
        next.vhosts.remove(at: index)
        return Result(config: next, warnings: [])
    }

    public func setEnabled(id: UUID, _ enabled: Bool, in config: RampConfig) throws -> Result {
        guard let index = config.vhosts.firstIndex(where: { $0.id == id }) else {
            throw VhostCatalogError.notFound(id)
        }
        var next = config
        next.vhosts[index].enabled = enabled
        return try commit(next, from: config, touched: id)
    }

    /// Moves the given vhosts into `group` (`nil`/blank = ungrouped). Organizational only — validated like
    /// any change (the group name itself must be valid), unknown ids throw `notFound`.
    public func setGroup(ids: Set<UUID>, _ group: String?, in config: RampConfig) throws -> Result {
        let normalized = Vhost.normalizeGroup(group)
        if let problem = VhostValidator.groupProblem(normalized) {
            throw VhostValidationError(issues: [VhostIssue(vhostID: ids.count == 1 ? ids.first : nil, field: .group,
                                                           severity: .error, message: "Group \(problem)")])
        }
        var next = config
        var found = Set<UUID>()
        for index in next.vhosts.indices where ids.contains(next.vhosts[index].id) {
            next.vhosts[index].group = normalized
            found.insert(next.vhosts[index].id)
        }
        if let missing = ids.subtracting(found).first { throw VhostCatalogError.notFound(missing) }
        return Result(config: next, warnings: [])
    }

    /// Fills `group` from `VhostGroupSuggester` for every vhost that has none (`nil`). Returns the new config
    /// and the ids that got a group; vhosts that already have a group are never touched.
    public static func autoGroup(_ config: RampConfig, sitesRoot: String) -> (config: RampConfig, changed: [UUID]) {
        var next = config
        var changed: [UUID] = []
        for index in next.vhosts.indices where Vhost.normalizeGroup(next.vhosts[index].group) == nil {
            if let suggestion = VhostGroupSuggester.suggest(docroot: next.vhosts[index].docroot, sitesRoot: sitesRoot) {
                next.vhosts[index].group = suggestion
                changed.append(next.vhosts[index].id)
            }
        }
        return (next, changed)
    }

    /// Sorted, deduplicated (case-insensitive) hostnames of enabled vhosts — the exact list sent to
    /// the hosts helper.
    public static func enabledHostnames(in config: RampConfig) -> [String] {
        Set(config.vhosts.filter(\.enabled).flatMap(\.hostnames).map { $0.lowercased() }).sorted()
    }

    /// Lowercases/trims domain and aliases (appending the default TLD to dot-less names),
    /// drops empty and duplicate aliases, strips trailing slashes from the docroot.
    public static func normalized(_ vhost: Vhost, tld: String) -> Vhost {
        var v = vhost
        v.domain = Vhost.normalizeDomain(vhost.domain, tld: tld)
        var seen = Set<String>()
        v.aliases = vhost.aliases
            .map { Vhost.normalizeDomain($0, tld: tld) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        v.docroot = VhostValidator.stripTrailingSlash(vhost.docroot.trimmingCharacters(in: .whitespaces))
        if let branch = v.phpBranch?.trimmingCharacters(in: .whitespaces) {
            v.phpBranch = branch.isEmpty ? nil : branch
        }
        v.group = Vhost.normalizeGroup(vhost.group)
        return v
    }

    // MARK: private

    /// Blocks on errors of the touched vhost, and on any error the change newly introduced
    /// (e.g. an update making another vhost's alias a duplicate). Pre-existing errors of untouched
    /// vhosts (MAMP import leftovers) do not block unrelated edits.
    private func commit(_ next: RampConfig, from previous: RampConfig, touched: UUID) throws -> Result {
        let before = validator(previous).validate().filter { $0.severity == .error }
        let after = validator(next).validate()
        let blocking = after.filter {
            $0.severity == .error && ($0.vhostID == touched || !before.contains($0))
        }
        guard blocking.isEmpty else { throw VhostValidationError(issues: blocking) }
        let warnings = after.filter { $0.severity == .warning && ($0.vhostID == touched || $0.vhostID == nil) }
        return Result(config: next, warnings: warnings)
    }

    private func validator(_ config: RampConfig) -> VhostValidator {
        VhostValidator(config: config, paths: paths, fs: fs, home: home)
    }
}
