import Foundation

public enum ImportSource: String, Sendable, Equatable {
    /// Taken from the `<VirtualHost *:80>` block.
    case http
    /// The :80 block only redirects to HTTPS (or is missing); data taken from `<VirtualHost *:443>`.
    case sslOnly
}

public enum ImportSkipReason: String, Sendable, Equatable {
    /// `ServerName ___default___`.
    case catchAll
    /// `localhost` — RAMP owns http://localhost/ + /phpmyadmin.
    case reservedLocalhost
    /// :80 block only redirects and there is no matching :443 block.
    case redirectOnly
    /// Domain (or alias) already configured in RAMP — the existing vhost wins.
    case existsInRamp
    /// Same name defined twice in MAMP (the HTTP block wins).
    case duplicate
    /// Block without `ServerName`.
    case noServerName
}

public struct SkippedHost: Sendable, Equatable {
    public var serverName: String
    public var reason: ImportSkipReason

    public init(serverName: String, reason: ImportSkipReason) {
        self.serverName = serverName
        self.reason = reason
    }
}

public struct ImportCandidate: Sendable, Equatable, Identifiable {
    public var vhost: Vhost
    public var source: ImportSource
    /// Proposed for import. `false` when any error issue exists (the user may fix and re-enable in the wizard).
    public var include: Bool
    /// Validator issues for this vhost + import warnings (HTTPS-only, PHP fallback).
    public var issues: [VhostIssue]
    /// Original MAMP PHP version (`8.3.14`), for display.
    public var mampPHPVersion: String?

    public var id: UUID { vhost.id }
}

public struct ImportSummary: Sendable, Equatable {
    public var candidates: Int
    public var included: Int
    public var excluded: Int
    public var sslOnly: Int
    public var skipped: Int
    public var warnings: Int
    public var errors: Int
}

public struct ImportPlan: Sendable, Equatable {
    /// Sorted by domain.
    public var candidates: [ImportCandidate]
    /// In MAMP file order (HTTP first, then SSL).
    public var skipped: [SkippedHost]
    /// Config-wide validator issues (limits), `vhostID == nil`.
    public var issues: [VhostIssue]

    /// Vhosts to hand to `VhostCatalog.add` (included candidates only).
    public var vhostsToAdd: [Vhost] { candidates.filter(\.include).map(\.vhost) }

    public var summary: ImportSummary {
        let all = candidates.flatMap(\.issues)
        return ImportSummary(
            candidates: candidates.count,
            included: candidates.filter(\.include).count,
            excluded: candidates.filter { !$0.include }.count,
            sslOnly: candidates.filter { $0.source == .sslOnly }.count,
            skipped: skipped.count,
            warnings: all.filter { $0.severity == .warning }.count,
            errors: all.filter { $0.severity == .error }.count + issues.filter { $0.severity == .error }.count)
    }
}

/// MAMP vhosts + current RampConfig → `ImportPlan` (plan 07-03). Pure dry-run: no writes, no network,
/// no processes; filesystem metadata only through `FileChecking` (via `VhostValidator`).
public enum MAMPImportPlanner {
    public static func plan(http: [MAMPVhost], ssl: [MAMPVhost], existing: RampConfig,
                            availableBranches: Set<String>, files: any FileChecking,
                            paths: Paths = .standard(),
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            makeID: () -> UUID = { UUID() }) -> ImportPlan {
        // MAMP names are taken as-is (trimmed, lowercased) — no default TLD is appended on import.
        func normalize(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }
        let sitesRoot = VhostGroupSuggester.sitesRoot(home: home)
        var skipped: [SkippedHost] = []

        let existingNames = Set(existing.vhosts.flatMap(\.hostnames).map { normalize($0) })
        var sslByName: [String: MAMPVhost] = [:]
        for host in ssl where !host.serverName.isEmpty && sslByName[host.serverName] == nil {
            sslByName[host.serverName] = host
        }

        struct Raw { var host: MAMPVhost; var source: ImportSource }
        var raws: [Raw] = []
        var claimed = Set<String>()     // names taken by a raw candidate (or skipped as existing)
        var consumedSSL = Set<String>()

        func special(_ name: String) -> ImportSkipReason? {
            if name.isEmpty { return .noServerName }
            if name == "___default___" { return .catchAll }
            if name == "localhost" || name.hasSuffix(".localhost") { return .reservedLocalhost }
            return nil
        }

        func consider(_ host: MAMPVhost, source: ImportSource, name: String) {
            if existingNames.contains(name) {
                skipped.append(SkippedHost(serverName: name, reason: .existsInRamp))
            } else if claimed.contains(name) {
                skipped.append(SkippedHost(serverName: name, reason: .duplicate))
                return
            } else {
                raws.append(Raw(host: host, source: source))
            }
            claimed.insert(name)
        }

        for host in http {
            let name = normalize(host.serverName)
            if let reason = special(name) {
                skipped.append(SkippedHost(serverName: host.serverName, reason: reason))
                continue
            }
            if host.documentRoot == nil, host.redirectTarget != nil {
                if let secure = sslByName[host.serverName] {
                    consumedSSL.insert(host.serverName)
                    consider(secure, source: .sslOnly, name: name)
                } else {
                    skipped.append(SkippedHost(serverName: name, reason: .redirectOnly))
                }
                continue
            }
            consider(host, source: .http, name: name)
        }
        for host in ssl where !consumedSSL.contains(host.serverName) {
            let name = normalize(host.serverName)
            if special(name) != nil { continue } // SSL catch-all / localhost: already reported via HTTP
            if host.documentRoot == nil, host.redirectTarget != nil { continue }
            consider(host, source: .sslOnly, name: name)
        }

        // Build vhosts (sorted by domain) + import warnings.
        var candidates: [ImportCandidate] = raws
            .map { raw -> (Raw, String) in (raw, normalize(raw.host.serverName)) }
            .sorted { $0.1 < $1.1 }
            .map { raw, domain in
                let id = makeID()
                var warnings: [VhostIssue] = []
                if raw.source == .sslOnly {
                    warnings.append(VhostIssue(vhostID: id, field: .domain, severity: .warning,
                        message: "\(domain): v MAMPe len HTTPS — importuje sa ako HTTP; projekt môže vynucovať https"))
                }
                // Aliases already used by an existing RAMP vhost are dropped (the existing vhost wins).
                var aliases: [String] = []
                for alias in raw.host.aliases.map(normalize) {
                    if existingNames.contains(alias) {
                        warnings.append(VhostIssue(vhostID: id, field: .alias, severity: .warning,
                            message: "Alias \(alias) už v RAMP existuje — vynechaný"))
                    } else if !aliases.contains(alias), alias != domain {
                        aliases.append(alias)
                    }
                }
                let (branch, phpWarning) = mapPHP(raw.host.phpVersion, available: availableBranches, domain: domain)
                if let phpWarning { warnings.append(VhostIssue(vhostID: id, field: .php, severity: .warning, message: phpWarning)) }
                let docroot = raw.host.documentRoot.map(VhostValidator.stripTrailingSlash) ?? ""
                let vhost = Vhost(id: id, domain: domain, aliases: aliases, docroot: docroot,
                                  phpBranch: branch, enabled: true,
                                  group: VhostGroupSuggester.suggest(docroot: docroot, sitesRoot: sitesRoot))
                return ImportCandidate(vhost: vhost, source: raw.source, include: true, issues: warnings,
                                       mampPHPVersion: raw.host.phpVersion)
            }

        // Validate in the context of existing + included candidates until stable; a candidate with an
        // error is excluded and the rest re-validated without it (its conflicts don't poison others).
        let importWarnings = candidates.map(\.issues)
        var validatorIssues: [UUID: [VhostIssue]] = [:]
        var configIssues: [VhostIssue] = []
        while true {
            var config = existing
            config.vhosts += candidates.filter(\.include).map(\.vhost)
            let issues = VhostValidator(config: config, paths: paths, fs: files, home: home).validate()
            configIssues = issues.filter { $0.vhostID == nil }
            var newlyExcluded = false
            for index in candidates.indices where candidates[index].include {
                let own = issues.filter { $0.vhostID == candidates[index].vhost.id }
                validatorIssues[candidates[index].vhost.id] = own
                if own.contains(where: { $0.severity == .error }) {
                    candidates[index].include = false
                    newlyExcluded = true
                }
            }
            if !newlyExcluded { break }
        }
        for index in candidates.indices {
            candidates[index].issues = importWarnings[index] + (validatorIssues[candidates[index].vhost.id] ?? [])
        }

        return ImportPlan(candidates: candidates, skipped: skipped, issues: configIssues)
    }

    /// MAMP PHP branch → RAMP branch it is deliberately moved to on import (applied when the target is
    /// available; otherwise the normal mapping below runs on the original branch).
    /// 7.3 → 7.4: PHP 7.3 mysqlnd cannot authenticate `caching_sha2_password` users (MySQL 8.4/9.x default);
    /// 7.4 can, so no `sha256_password` user conversion is needed (ISS-004).
    public static let phpBranchRemap: [String: String] = ["7.3": "7.4"]

    /// `8.3.14` → `8.3` if available (`phpBranchRemap` first: `7.3.33` → `7.4` + warning); else nearest
    /// higher available branch of the same major (+ warning); else `nil` (Apache default branch) + warning.
    /// No version → `nil`, no warning.
    static func mapPHP(_ version: String?, available: Set<String>, domain: String) -> (String?, String?) {
        guard let version else { return (nil, nil) }
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return (nil, "Neznáma PHP verzia \(version) pre \(domain) — použije sa predvolená") }
        let major = String(parts[0])
        let branch = "\(parts[0]).\(parts[1])"
        if let target = phpBranchRemap[branch], available.contains(target) {
            return (target, "PHP \(version) z MAMPu → \(domain) použije PHP \(target) (7.3 nevie caching_sha2_password)")
        }
        if available.contains(branch) { return (branch, nil) }
        let higher = available
            .filter { $0.split(separator: ".").first.map(String.init) == major && UpdatePolicy.branchLess(branch, $0) }
            .sorted(by: UpdatePolicy.branchLess)
            .first
        if let higher {
            return (higher, "PHP \(version) z MAMPu nie je v RAMP — \(domain) použije PHP \(higher)")
        }
        return (nil, "PHP \(version) z MAMPu nie je v RAMP — \(domain) použije predvolenú PHP vetvu")
    }
}
