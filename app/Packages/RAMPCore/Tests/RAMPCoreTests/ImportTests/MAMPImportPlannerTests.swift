import Foundation
import Testing
@testable import RAMPCore

@Suite struct MAMPImportPlannerTests {
    static let branches: Set<String> = ["7.3", "7.4", "8.1", "8.2", "8.3", "8.4"]

    /// Every fixture docroot exists except `api.missing.local`'s.
    static func fs() throws -> FakeFileChecking {
        var fs = FakeFileChecking()
        for host in try MAMPFixtures.http() + MAMPFixtures.ssl() {
            if let root = host.documentRoot, !root.contains("/missing/") { fs.kinds[root] = .directory }
        }
        return fs
    }

    private func ids() -> () -> UUID {
        var n = 0
        return {
            n += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        }
    }

    private func plan(existing: RampConfig = VhostFixtures.baseConfig(php: ["7.3", "7.4", "8.1", "8.2", "8.3", "8.4"]),
                      http: [MAMPVhost]? = nil, ssl: [MAMPVhost]? = nil,
                      branches: Set<String> = branches) throws -> ImportPlan {
        MAMPImportPlanner.plan(http: try http ?? MAMPFixtures.http(), ssl: try ssl ?? MAMPFixtures.ssl(),
                               existing: existing, availableBranches: branches, files: try Self.fs(),
                               paths: VhostFixtures.paths, home: VhostFixtures.home, makeID: ids())
    }

    private func candidate(_ domain: String, _ p: ImportPlan) throws -> ImportCandidate {
        try #require(p.candidates.first { $0.vhost.domain == domain })
    }

    @Test func fixtureCandidatesSortedByDomain() throws {
        let p = try plan()
        #expect(p.candidates.map(\.vhost.domain) == [
            "api.missing.local", "front.project-b.local", "legacy.local", "old.local", "project-a.local",
            "secure-a.local", "secure-b.local", "seventyfour.local", "shop.local", "static.local",
        ])
    }

    @Test func skippedReasons() throws {
        let p = try plan()
        #expect(p.skipped == [
            SkippedHost(serverName: "___default___", reason: .catchAll),
            SkippedHost(serverName: "localhost", reason: .reservedLocalhost),
            SkippedHost(serverName: "redirect-only.local", reason: .redirectOnly),
            SkippedHost(serverName: "project-a.local", reason: .duplicate),
        ])
    }

    @Test func phpBranchMapping() throws {
        let p = try plan()
        #expect(try candidate("legacy.local", p).vhost.phpBranch == "7.4")  // MAMP 7.3.33 → 7.4 (remap)
        #expect(try candidate("seventyfour.local", p).vhost.phpBranch == "7.4")
        #expect(try candidate("old.local", p).vhost.phpBranch == "8.1")
        #expect(try candidate("shop.local", p).vhost.phpBranch == "8.2")
        #expect(try candidate("project-a.local", p).vhost.phpBranch == "8.3")
        #expect(try candidate("front.project-b.local", p).vhost.phpBranch == "8.4")
        #expect(try candidate("static.local", p).vhost.phpBranch == nil)
        #expect(try candidate("static.local", p).issues.isEmpty)
    }

    @Test func mampSevenThreeMovesToSevenFour() throws {
        #expect(MAMPImportPlanner.phpBranchRemap == ["7.3": "7.4"])
        let c = try candidate("legacy.local", try plan())
        #expect(c.vhost.phpBranch == "7.4")
        #expect(c.include)
        #expect(c.mampPHPVersion == "7.3.33")
        #expect(c.issues.contains { $0.field == .php && $0.severity == .warning && $0.message.contains("7.3.33")
            && $0.message.contains("PHP 7.4") })
        // A native 7.4 host maps without a warning.
        #expect(try candidate("seventyfour.local", try plan()).issues.isEmpty)
    }

    @Test func sevenThreeStaysWhenSevenFourUnavailable() throws {
        let c = try candidate("legacy.local", try plan(branches: ["7.3", "8.1", "8.2", "8.3", "8.4"]))
        #expect(c.vhost.phpBranch == "7.3")
        #expect(!c.issues.contains { $0.field == .php })
    }

    @Test func sevenThreeWithoutSevenBranchesFallsBackToNil() throws {
        let c = try candidate("legacy.local", try plan(branches: ["8.1", "8.2", "8.3", "8.4"]))
        #expect(c.vhost.phpBranch == nil)
        #expect(c.issues.contains { $0.field == .php && $0.severity == .warning && $0.message.contains("7.3.33") })
    }

    @Test func unavailableBranchFallsBackToNilForSevenFour() throws {
        let c = try candidate("seventyfour.local", try plan(branches: ["7.3", "8.1", "8.2", "8.3", "8.4"]))
        #expect(c.vhost.phpBranch == nil)
        #expect(c.include)
        #expect(c.issues.contains { $0.field == .php && $0.severity == .warning && $0.message.contains("7.4.33") })
    }

    @Test func unavailableBranchUsesNearestHigherSameMajor() throws {
        // 8.2 not offered → 8.3 (nearest higher 8.x), not 8.4 and not 7.3.
        var existing = VhostFixtures.baseConfig(php: ["7.3", "8.1", "8.3", "8.4"])
        existing.vhosts = []
        let c = try candidate("shop.local", try plan(existing: existing, branches: ["7.3", "8.1", "8.3", "8.4"]))
        #expect(c.vhost.phpBranch == "8.3")
        #expect(c.issues.contains { $0.field == .php && $0.severity == .warning && $0.message.contains("8.2.26") })
    }

    @Test func sslOnlyHostsComeFromSSLBlock() throws {
        let p = try plan()
        let a = try candidate("secure-a.local", p)
        #expect(a.source == .sslOnly)
        #expect(a.vhost.docroot == "/Users/test/Sites/secure-a/api/public")
        #expect(a.vhost.phpBranch == "7.4")  // MAMP 7.3 → 7.4
        #expect(a.include)
        #expect(a.issues.contains { $0.severity == .warning && $0.message.contains("v MAMPe len HTTPS") })
        let b = try candidate("secure-b.local", p)
        #expect(b.vhost.aliases == ["www.secure-b.local"])
        #expect(b.source == .sslOnly)
        #expect(try candidate("project-a.local", p).source == .http)
    }

    @Test func missingDocrootExcludedWithValidatorError() throws {
        let c = try candidate("api.missing.local", try plan())
        #expect(!c.include)
        #expect(c.issues.contains { $0.field == .docroot && $0.severity == .error })
    }

    @Test func regularHostsIncludedWithoutIssues() throws {
        let c = try candidate("project-a.local", try plan())
        #expect(c.include)
        #expect(c.issues.isEmpty)
        #expect(c.vhost.aliases == ["admin.project-a.local"])
        #expect(c.vhost.enabled)
        #expect(c.vhost.docroot == "/Users/test/Sites/project-a/public")
    }

    @Test func existingRampDomainOrAliasSkipped() throws {
        var existing = VhostFixtures.baseConfig(php: ["7.3", "8.1", "8.2", "8.3", "8.4"])
        existing.vhosts = [
            Vhost(domain: "Legacy.local", docroot: "/Users/test/Sites/legacy/www"),
            Vhost(domain: "other.local", aliases: ["old.local"], docroot: "/Users/test/Sites/old/www"),
        ]
        let p = try plan(existing: existing)
        #expect(p.skipped.contains(SkippedHost(serverName: "legacy.local", reason: .existsInRamp)))
        #expect(p.skipped.contains(SkippedHost(serverName: "old.local", reason: .existsInRamp)))
        #expect(!p.candidates.contains { $0.vhost.domain == "legacy.local" || $0.vhost.domain == "old.local" })
    }

    @Test func noPHPMeansNil() throws {
        let http = [MAMPVhost(serverName: "plain.local", aliases: [], documentRoot: "/Users/test/Sites/static",
                              phpVersion: nil, redirectTarget: nil, line: 1)]
        let p = try plan(http: http, ssl: [])
        #expect(p.candidates.first?.vhost.phpBranch == nil)
    }

    @Test func deterministicIDsAndOutput() throws {
        #expect(try plan() == plan())
    }

    @Test func summaryCounts() throws {
        let s = try plan().summary
        #expect(s.candidates == 10)
        #expect(s.included == 9)
        #expect(s.excluded == 1)
        #expect(s.sslOnly == 2)
        #expect(s.skipped == 4)
        #expect(s.warnings >= 4) // 2× HTTPS-only + 2× 7.3 → 7.4 (legacy, secure-a)
    }

    @Test func locatorPointsIntoMAMPProSupportDir() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let loc = MAMPLocator.locate(home: home)
        #expect(loc.httpConf.path == "/Users/test/Library/Application Support/appsolute/MAMP PRO/httpd.conf")
        #expect(loc.sslConf.path == "/Users/test/Library/Application Support/appsolute/MAMP PRO/httpd-ssl.conf")
        #expect(!loc.httpReadable) // does not exist
    }
}
