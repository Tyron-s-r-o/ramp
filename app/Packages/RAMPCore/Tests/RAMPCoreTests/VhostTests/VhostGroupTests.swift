import Foundation
import Testing
@testable import RAMPCore

@Suite struct VhostGroupSuggesterTests {
    static let sites = "/Users/tester/Sites"

    @Test(arguments: [
        ("/Users/tester/Sites/ASTEEL/tyrefleet.eu/public", "ASTEEL"),
        ("/Users/tester/Sites/ASTEEL/tyrestock/new/api/public", "ASTEEL"),
        ("/Users/tester/Sites/ASTEEL/Asteel.sk - Front/public", "ASTEEL"),
        ("/Users/tester/Sites/mtech/tyrion/public/", "mtech"),
        ("/Users/tester/sites/ASTEEL/x/public", "ASTEEL"),              // APFS is case-insensitive
        ("/Users/tester/Sites//ASTEEL/./x/public", "ASTEEL"),
    ])
    func suggestsFirstFolderWhenTwoLevelsDeep(docroot: String, expected: String) {
        #expect(VhostGroupSuggester.suggest(docroot: docroot, sitesRoot: Self.sites) == expected)
    }

    @Test(arguments: [
        "/Users/tester/Sites/chargeo/public",           // project directly in Sites
        "/Users/tester/Sites/chargeo",
        "/Users/tester/Sites",
        "/Users/tester/Projects/ASTEEL/x/public",       // outside Sites
        "/Users/tester/SitesOld/ASTEEL/x/public",       // prefix of a different folder
        "/Users/tester/Sites/../Projects/ASTEEL/x/public",
        "relative/Sites/ASTEEL/x/public",
        "",
    ])
    func noSuggestion(docroot: String) {
        #expect(VhostGroupSuggester.suggest(docroot: docroot, sitesRoot: Self.sites) == nil)
    }

    @Test func sitesRootTrailingSlashAndLongNames() {
        #expect(VhostGroupSuggester.suggest(docroot: "/Users/tester/Sites/A/b/c", sitesRoot: "/Users/tester/Sites/") == "A")
        let long = String(repeating: "x", count: 60)
        let suggestion = VhostGroupSuggester.suggest(docroot: "/Users/tester/Sites/\(long)/b/c", sitesRoot: Self.sites)
        #expect(suggestion?.count == Vhost.maxGroupLength)
    }

    @Test func sitesRootOfHome() {
        #expect(VhostGroupSuggester.sitesRoot(home: VhostFixtures.home) == "/Users/tester/Sites/")
        #expect(VhostGroupSuggester.suggest(docroot: "/Users/tester/Sites/A/b/c",
                                            sitesRoot: VhostGroupSuggester.sitesRoot(home: VhostFixtures.home)) == "A")
    }
}

@Suite struct VhostGroupModelTests {
    typealias F = VhostFixtures

    @Test func oldJSONWithoutGroupDecodesAndNilIsNotWritten() throws {
        let id = UUID()
        let json = #"{"schemaVersion":1,"vhosts":[{"id":"\#(id.uuidString)","domain":"a.local","docroot":"/p"}]}"#
        let config = try JSONDecoder().decode(RampConfig.self, from: Data(json.utf8))
        #expect(config.vhosts[0].group == nil)
        let encoded = String(decoding: try JSONEncoder().encode(config.vhosts[0]), as: UTF8.self)
        #expect(!encoded.contains("group"))
    }

    @Test func groupRoundTrips() throws {
        var config = RampConfig()
        config.vhosts = [Vhost(domain: "a.local", docroot: "/p", group: "ASTEEL")]
        let decoded = try JSONDecoder().decode(RampConfig.self, from: try JSONEncoder().encode(config))
        #expect(decoded.vhosts[0].group == "ASTEEL")
        #expect(decoded.schemaVersion == 1)
    }

    @Test func normalizeGroup() {
        #expect(Vhost.normalizeGroup("  ASTEEL \n") == "ASTEEL")
        #expect(Vhost.normalizeGroup("   ") == nil)
        #expect(Vhost.normalizeGroup(nil) == nil)
    }

    @Test(arguments: ["A\nB", "A\tB", "A\u{0}B", "A\u{2028}B", String(repeating: "x", count: 41)])
    func validatorRejectsBadGroups(group: String) {
        var config = F.mampConfig()
        config.vhosts[0].group = group
        let issues = F.validator(config, fs: F.mampFS()).validate()
        #expect(issues.contains { $0.field == .group && $0.severity == .error && $0.vhostID == F.ids[0] })
    }

    @Test func validatorAcceptsGoodGroups() {
        var config = F.mampConfig()
        config.vhosts[0].group = String(repeating: "x", count: 40)
        config.vhosts[1].group = "Asteel.sk - Front ✓"
        #expect(F.validator(config, fs: F.mampFS()).validate().isEmpty)
    }

    @Test func catalogNormalizesGroupOnAddAndUpdate() throws {
        var fs = F.mampFS()
        fs.kinds["/Users/tester/Sites/shop"] = .directory
        let catalog = F.catalog(fs: fs)
        let added = try catalog.add(Vhost(domain: "shop", docroot: "/Users/tester/Sites/shop", group: "  Shops "),
                                    in: F.mampConfig()).config
        #expect(added.vhosts.last?.group == "Shops")
        var v = try #require(added.vhosts.last)
        v.group = "  "
        #expect(try catalog.update(v, in: added).config.vhosts.last?.group == nil)
        v.group = "a\nb"
        #expect(throws: VhostValidationError.self) { try catalog.update(v, in: added) }
    }

    @Test func setGroupMovesSelectionAndClears() throws {
        let catalog = F.catalog(fs: F.mampFS())
        let moved = try catalog.setGroup(ids: [F.ids[0], F.ids[1]], " ASTEEL ", in: F.mampConfig()).config
        #expect(moved.vhosts.map(\.group) == ["ASTEEL", "ASTEEL", nil, nil, nil])
        let cleared = try catalog.setGroup(ids: [F.ids[1]], nil, in: moved).config
        #expect(cleared.vhosts.map(\.group) == ["ASTEEL", nil, nil, nil, nil])
        #expect(throws: VhostValidationError.self) { try catalog.setGroup(ids: [F.ids[0]], "a\nb", in: moved) }
        #expect(throws: VhostCatalogError.notFound(F.ids[0])) {
            try catalog.setGroup(ids: [F.ids[0]], "X", in: RampConfig())
        }
    }

    @Test func autoGroupFillsOnlyUngrouped() {
        var config = F.baseConfig()
        config.vhosts = [
            Vhost(id: F.ids[0], domain: "a.local", docroot: "/Users/tester/Sites/ASTEEL/a/public"),
            Vhost(id: F.ids[1], domain: "b.local", docroot: "/Users/tester/Sites/ASTEEL/b/public", group: "Mine"),
            Vhost(id: F.ids[2], domain: "c.local", docroot: "/Users/tester/Sites/chargeo/public"),
            Vhost(id: F.ids[3], domain: "d.local", docroot: "/Users/tester/Sites/mtech/d/public"),
        ]
        let (next, changed) = VhostCatalog.autoGroup(config, sitesRoot: "/Users/tester/Sites")
        #expect(changed == [F.ids[0], F.ids[3]])
        #expect(next.vhosts.map(\.group) == ["ASTEEL", "Mine", nil, "mtech"])
        #expect(VhostCatalog.autoGroup(next, sitesRoot: "/Users/tester/Sites").changed.isEmpty)
    }

    @Test func groupDoesNotAffectApacheOrHostsOutput() {
        var grouped = F.mampConfig()
        grouped.vhosts[0].group = "ASTEEL"
        #expect(VhostCatalog.enabledHostnames(in: grouped) == VhostCatalog.enabledHostnames(in: F.mampConfig()))
    }

    @Test func mampImportSuggestsGroups() throws {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let hosts = [
            MAMPVhost(serverName: "a.local", aliases: [], documentRoot: "/Users/test/Sites/ASTEEL/a/public",
                      phpVersion: nil, redirectTarget: nil, line: 1),
            MAMPVhost(serverName: "b.local", aliases: [], documentRoot: "/Users/test/Sites/b/public",
                      phpVersion: nil, redirectTarget: nil, line: 1),
        ]
        var fs = FakeFileChecking()
        for h in hosts { fs.kinds[h.documentRoot!] = .directory }
        let plan = MAMPImportPlanner.plan(http: hosts, ssl: [], existing: F.baseConfig(), availableBranches: ["8.3"],
                                          files: fs, paths: F.paths, home: home)
        #expect(plan.candidates.map(\.vhost.group) == ["ASTEEL", nil])
    }
}

@Suite(.serialized) struct VhostGroupServiceTests {
    @Test func setGroupAndAutoGroupSaveWithoutApplyOrHosts() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        var fs = FakeFileChecking()
        for d in ["/Users/tester/Sites/ASTEEL/a/public", "/Users/tester/Sites/b/public"] { fs.kinds[d] = .directory }
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: VhostCatalog(paths: env.paths, fs: fs, home: URL(filePath: "/Users/tester")))
        try await service.addMany([
            Vhost(domain: "a.local", docroot: "/Users/tester/Sites/ASTEEL/a/public"),
            Vhost(domain: "b.local", docroot: "/Users/tester/Sites/b/public"),
        ])
        let appliedBefore = applier.appliedDomains.count
        let hostCallsBefore = hosts.calls.count

        let changed = try await service.autoGroup(sitesRoot: "/Users/tester/Sites")
        #expect(changed.count == 1)
        #expect(try await service.find("a.local").group == "ASTEEL")

        let b = try await service.find("b.local")
        try await service.setGroup(ids: [b.id], "Misc")
        #expect(try await service.find("b.local").group == "Misc")
        try await service.setGroup(ids: [b.id], nil)
        #expect(try await service.find("b.local").group == nil)

        #expect(applier.appliedDomains.count == appliedBefore)
        #expect(hosts.calls.count == hostCallsBefore)
    }
}
