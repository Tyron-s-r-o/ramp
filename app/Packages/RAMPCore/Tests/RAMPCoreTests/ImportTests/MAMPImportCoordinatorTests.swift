import Foundation
import Testing
@testable import RAMPCore

@Suite(.serialized) struct MAMPImportCoordinatorTests {
    private static func catalog(_ paths: Paths, docroots: [String]) -> VhostCatalog {
        var fs = FakeFileChecking()
        for d in docroots { fs.kinds[d] = .directory }
        return VhostCatalog(paths: paths, fs: fs, home: URL(filePath: "/Users/tester"))
    }

    @Test func addManyIsOneSaveOneApplyOneHostsSync() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a", "/Users/tester/Sites/b"]))
        let result = try await service.addMany([
            Vhost(domain: "a.local", aliases: ["www.a.local"], docroot: "/Users/tester/Sites/a"),
            Vhost(domain: "b.local", docroot: "/Users/tester/Sites/b"),
        ])
        #expect(result.config.vhosts.map(\.domain) == ["a.local", "b.local"])
        #expect(applier.appliedDomains == [["a.local", "b.local"]])
        #expect(hosts.calls == [["a.local", "b.local", "www.a.local"]])
    }

    @Test func addManyValidationErrorWritesNothing() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        let before = try await store.load()
        await #expect(throws: VhostValidationError.self) {
            try await service.addMany([
                Vhost(domain: "a.local", docroot: "/Users/tester/Sites/a"),
                Vhost(domain: "a.local", docroot: "/Users/tester/Sites/a"),   // duplicate domain
            ])
        }
        #expect(try await store.load() == before)
        #expect(applier.appliedDomains.isEmpty)
        #expect(hosts.calls.isEmpty)
    }

    @Test func addManyApacheRejectionRollsBackEverything() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        let before = try await store.load()
        await #expect(throws: VhostServiceError.self) {
            try await service.addMany([
                Vhost(domain: "good.local", docroot: "/Users/tester/Sites/a"),
                Vhost(domain: "bad.local", docroot: "/Users/tester/Sites/a"),
            ])
        }
        #expect(try await store.load() == before)
        #expect(hosts.calls.isEmpty)
    }

    @Test func wizardStatePersistsAndMarksInterruptedRuns() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: FakeHostsSync(channel: .helper))
        func coordinator() -> MAMPImportCoordinator {
            MAMPImportCoordinator(paths: env.paths, store: store, vhostService: service, lock: MaintenanceLock(),
                                  elasticsearch: ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(),
                                                                          rampRunning: { false }),
                                  location: { nil })
        }
        let first = coordinator()
        await first.mark(.vhosts, .done, message: "3")
        _ = await first.skip(.mysql)
        await first.mark(.elasticsearch, .running)

        let reloaded = await coordinator().state()
        #expect(reloaded.status(.vhosts) == .done)
        #expect(reloaded.status(.mysql) == .skipped)
        #expect(reloaded.status(.elasticsearch) == .failed)
        #expect(reloaded.status(.launchAgent) == .notStarted)
        await #expect(throws: MAMPImportError.self) { try await coordinator().previewVhosts() }
    }

    @Test func esStepHoldsTheMaintenanceLock() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: FakeHostsSync(channel: .helper))
        let lock = MaintenanceLock()
        let coordinator = MAMPImportCoordinator(
            paths: env.paths, store: store, vhostService: service, lock: lock,
            elasticsearch: ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(), rampRunning: { false }),
            location: { nil })
        let src = try #require(ElasticsearchDataMigrator.source(at: try ElasticsearchDataMigratorTests.makeSource(env.dir)))

        let token = try await lock.acquire(.update)
        await #expect(throws: MaintenanceError.busy(.update)) {
            try await coordinator.runElasticsearch(src)
        }
        await lock.release(token)

        let observed = try await coordinator.runElasticsearch(src, smoke: {
            ["held": await lock.current == .mampImport ? 1 : 0]   // lock held while the step runs
        })
        #expect(observed.smokeIndices == ["held": 1])
        #expect(await lock.current == nil)
        #expect(await coordinator.state().status(.elasticsearch) == .done)

        // MySQL engine lock hook (07-04 MigrationLocking) maps to .mampImport.
        let release = try await lock.acquireForMySQLMigration()
        #expect(await lock.current == .mampImport)
        await release()
        #expect(await lock.current == nil)
    }

    @Test func launchAgentRemovalNeedsConfirmation() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: FakeHostsSync(channel: .helper))
        let runner = FakeLaunchctl()
        let coordinator = MAMPImportCoordinator(
            paths: env.paths, store: store, vhostService: service, lock: MaintenanceLock(),
            launchAgents: LegacyLaunchAgentRemover(launchAgentsDir: env.dir.appending(path: "LA"), runner: runner,
                                                   uid: 501, trash: { _ in nil }),
            location: { nil })
        let src = ElasticsearchSource(root: env.dir.appending(path: "es"), version: "9.5.4")
        let agent = LegacyAgent(label: "com.rv.elastic-autostop", plistURL: env.dir.appending(path: "LA/x.plist"),
                                programArguments: [])
        await #expect(throws: LegacyLaunchAgentError.notConfirmed) {
            try await coordinator.removeLegacyAgent(agent, source: src, confirmed: false)
        }
        #expect(runner.argvs.isEmpty)
    }
}
