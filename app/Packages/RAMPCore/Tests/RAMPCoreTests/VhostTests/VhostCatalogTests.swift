import Foundation
import Testing
@testable import RAMPCore

@Suite struct VhostCatalogTests {
    typealias F = VhostFixtures

    private func fsWith(_ extra: String...) -> FakeFileChecking {
        var fs = F.mampFS()
        for p in extra { fs.kinds[p] = .directory }
        return fs
    }

    @Test func addNormalizes() throws {
        let catalog = F.catalog(fs: fsWith("/Users/tester/Sites/shop"))
        let input = Vhost(domain: "  Shop ", aliases: ["WWW.Shop.local", "www.shop.local", "api"],
                          docroot: "/Users/tester/Sites/shop/")
        let result = try catalog.add(input, in: F.mampConfig())
        let added = try #require(result.config.vhosts.last)
        #expect(result.config.vhosts.count == 6)
        #expect(added.domain == "shop.local")
        #expect(added.aliases == ["www.shop.local", "api.local"])
        #expect(added.docroot == "/Users/tester/Sites/shop")
        #expect(result.warnings.isEmpty)
    }

    @Test func addGeneratesNewIDOnCollision() throws {
        let catalog = F.catalog(fs: fsWith("/Users/tester/Sites/shop"))
        let input = Vhost(id: F.ids[0], domain: "shop.local", docroot: "/Users/tester/Sites/shop")
        let result = try catalog.add(input, in: F.mampConfig())
        let added = try #require(result.config.vhosts.last)
        #expect(added.id != F.ids[0])
        #expect(Set(result.config.vhosts.map(\.id)).count == 6)
    }

    @Test func addDuplicateThrowsWithMessages() {
        let catalog = F.catalog(fs: fsWith("/Users/tester/Sites/shop"))
        let input = Vhost(domain: "shop.local", aliases: ["Admin.Asteel.local"], docroot: "/Users/tester/Sites/shop")
        do {
            _ = try catalog.add(input, in: F.mampConfig())
            Issue.record("expected VhostValidationError")
        } catch let error as VhostValidationError {
            #expect(error.issues.count == 1)
            #expect(error.errorDescription?.contains("Alias admin.asteel.local is already used by vhost asteel.local") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func addMissingDocrootEnabledThrowsDisabledWarns() throws {
        let catalog = F.catalog(fs: F.mampFS())
        let broken = Vhost(domain: "api.tyron.local", docroot: "/Users/tester/Sites/missing")
        #expect(throws: VhostValidationError.self) { try catalog.add(broken, in: F.mampConfig()) }

        var disabled = broken
        disabled.enabled = false
        let result = try catalog.add(disabled, in: F.mampConfig())
        #expect(result.config.vhosts.count == 6)
        #expect(result.warnings.map(\.field) == [.docroot])
    }

    @Test func setEnabledOnBrokenVhostThrows() throws {
        let catalog = F.catalog(fs: F.mampFS())
        let broken = Vhost(domain: "api.tyron.local", docroot: "/Users/tester/Sites/missing", enabled: false)
        let config = try catalog.add(broken, in: F.mampConfig()).config
        let id = try #require(config.vhosts.last?.id)
        #expect(throws: VhostValidationError.self) { try catalog.setEnabled(id: id, true, in: config) }
    }

    @Test func setEnabledTogglesFlag() throws {
        let catalog = F.catalog(fs: F.mampFS())
        let off = try catalog.setEnabled(id: F.ids[2], false, in: F.mampConfig()).config
        #expect(off.vhosts[2].enabled == false)
        let on = try catalog.setEnabled(id: F.ids[2], true, in: off).config
        #expect(on == F.mampConfig())
    }

    @Test func updateReplacesInPlace() throws {
        let catalog = F.catalog(fs: fsWith("/Users/tester/Sites/tyrestock/public"))
        var v = F.mampVhosts()[2]
        v.docroot = "/Users/tester/Sites/tyrestock/public/"
        v.phpBranch = "8.3"
        let result = try catalog.update(v, in: F.mampConfig())
        #expect(result.config.vhosts[2].docroot == "/Users/tester/Sites/tyrestock/public")
        #expect(result.config.vhosts[2].phpBranch == "8.3")
        #expect(result.config.vhosts.count == 5)
    }

    @Test func updateCreatingConflictThrows() {
        let catalog = F.catalog(fs: F.mampFS())
        var v = F.mampVhosts()[0]
        v.aliases.append("pneuprofi.local")
        #expect(throws: VhostValidationError.self) { try catalog.update(v, in: F.mampConfig()) }
    }

    @Test func unrelatedPreexistingErrorDoesNotBlockEdits() throws {
        var config = F.mampConfig()
        config.vhosts[3].phpBranch = "5.6"   // already broken, not touched below
        let catalog = F.catalog(fs: F.mampFS())
        let result = try catalog.setEnabled(id: F.ids[4], false, in: config)
        #expect(result.config.vhosts[4].enabled == false)
    }

    @Test func removeAndNotFound() throws {
        let catalog = F.catalog(fs: F.mampFS())
        let result = try catalog.remove(id: F.ids[1], in: F.mampConfig())
        #expect(result.config.vhosts.map(\.id) == [F.ids[0], F.ids[2], F.ids[3], F.ids[4]])

        let unknown = UUID()
        #expect(throws: VhostCatalogError.notFound(unknown)) { try catalog.remove(id: unknown, in: F.mampConfig()) }
        #expect(throws: VhostCatalogError.notFound(unknown)) {
            try catalog.update(Vhost(id: unknown, domain: "x.local", docroot: "/x"), in: F.mampConfig())
        }
        #expect(throws: VhostCatalogError.notFound(unknown)) {
            try catalog.setEnabled(id: unknown, false, in: F.mampConfig())
        }
    }

    @Test func enabledHostnamesSortedDedupedEnabledOnly() {
        var config = F.mampConfig()
        config.vhosts[2].enabled = false
        config.vhosts[3].aliases = ["TyreFleet.local"]   // case-dup of its own domain
        let names = VhostCatalog.enabledHostnames(in: config)
        #expect(names == names.sorted())
        #expect(!names.contains("tyrestock.local"))
        #expect(names.filter { $0 == "tyrefleet.local" }.count == 1)
        #expect(names.count == 2 + 7 + 1 + 1)
        #expect(names.first == "admin.asteel.local")
    }
}
