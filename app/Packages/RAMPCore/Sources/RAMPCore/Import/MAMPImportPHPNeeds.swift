import Foundation

/// A PHP branch MAMP vhosts need that RAMP has not installed but the manifest offers (typically an EOL branch
/// left out of the first-launch set): the import wizard offers to install it.
public struct MAMPPHPNeed: Sendable, Equatable, Identifiable {
    public let branch: String
    /// Domains of the candidates that would use it, sorted.
    public let domains: [String]
    public var id: String { branch }
}

extension MAMPImportPlanner {
    /// Branches the candidates' MAMP PHP versions map to (`phpBranchRemap` applied when its target is offered,
    /// e.g. 7.3 → 7.4) that are not `installed` but `offered`. Highest branch first.
    public static func installablePHPNeeds(candidates: [ImportCandidate], installed: Set<String>,
                                           offered: Set<String>) -> [MAMPPHPNeed] {
        var needs: [String: Set<String>] = [:]
        for candidate in candidates {
            guard let version = candidate.mampPHPVersion else { continue }
            let parts = version.split(separator: ".")
            guard parts.count >= 2 else { continue }
            var branch = "\(parts[0]).\(parts[1])"
            if let target = phpBranchRemap[branch], offered.contains(target) || installed.contains(target) {
                branch = target
            }
            guard !installed.contains(branch), offered.contains(branch) else { continue }
            needs[branch, default: []].insert(candidate.vhost.domain)
        }
        return needs.map { MAMPPHPNeed(branch: $0.key, domains: $0.value.sorted()) }
            .sorted { UpdatePolicy.branchLess($1.branch, $0.branch) }
    }
}
