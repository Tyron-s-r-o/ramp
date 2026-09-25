import Darwin
import Foundation
import Synchronization
import Testing
@testable import RAMPCore

/// Rejects (like `httpd -t`) any saved config containing a vhost whose domain starts with "bad".
final class FakeApplier: VhostConfigApplying, Sendable {
    let store: ConfigStore
    private let applied = Mutex<[[String]]>([])

    init(store: ConfigStore) { self.store = store }

    var appliedDomains: [[String]] { applied.withLock { $0 } }

    func applyVhostConfig() async throws {
        let domains = try await store.load().vhosts.map(\.domain)
        applied.withLock { $0.append(domains) }
        if domains.contains(where: { $0.hasPrefix("bad") }) {
            throw VhostServiceError.apacheRejected("Syntax error on line 3")
        }
    }
}

@Suite(.serialized) struct VhostServiceTests {
    private static func catalog(_ paths: Paths, docroots: [String]) -> VhostCatalog {
        var fs = FakeFileChecking()
        for d in docroots { fs.kinds[d] = .directory }
        return VhostCatalog(paths: paths, fs: fs, home: URL(filePath: "/Users/tester"))
    }

    @Test func addSavesAppliesAndSyncsHosts() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        let result = try await service.add(Vhost(domain: "shop", aliases: ["admin.shop.local"], docroot: "/Users/tester/Sites/a"))
        #expect(result.hosts == .synced(.updated(via: .helper)))
        #expect(try await store.load().vhosts.map(\.domain) == ["shop.local"])
        #expect(applier.appliedDomains == [["shop.local"]])
        #expect(hosts.calls == [["admin.shop.local", "shop.local"]])
        #expect(try await service.find("ADMIN.shop.local").domain == "shop.local")

        // Disable → hosts block without the names.
        let id = try await service.find("shop.local").id
        _ = try await service.setEnabled(id: id, false)
        #expect(hosts.calls.last == [])
        _ = try await service.remove(id: id)
        #expect(try await service.list().isEmpty)
    }

    @Test func apacheRejectionRollsBackConfigAndFiles() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: applier, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        try await service.add(Vhost(domain: "good.local", docroot: "/Users/tester/Sites/a"))
        let before = try await store.load()

        await #expect(throws: VhostServiceError.apacheRejected("Syntax error on line 3")) {
            try await service.add(Vhost(domain: "bad.local", docroot: "/Users/tester/Sites/a"))
        }
        #expect(try await store.load() == before)
        // Applied the bad config once, then re-applied the previous one.
        #expect(applier.appliedDomains.suffix(2) == [["good.local", "bad.local"], ["good.local"]])
        // Hosts only touched for the good vhost.
        #expect(hosts.calls == [["good.local"]])
    }

    @Test func validationErrorWritesNothing() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let applier = FakeApplier(store: store)
        let service = VhostService(store: store, applier: applier, hosts: FakeHostsSync(channel: .helper),
                                   catalog: Self.catalog(env.paths, docroots: []))
        await #expect(throws: VhostValidationError.self) {
            try await service.add(Vhost(domain: "a.local", docroot: "/Users/tester/Sites/missing"))
        }
        #expect(applier.appliedDomains.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.paths.configFile.path(percentEncoded: false)))
    }

    @Test func hostsFailureDoesNotRollBackTheVhost() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let hosts = FakeHostsSync(channel: .adminPrompt, error: .cancelled)
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        let result = try await service.add(Vhost(domain: "a.local", docroot: "/Users/tester/Sites/a"))
        #expect(result.hosts == .pending(reason: HostsSyncError.cancelled.localizedDescription))
        #expect(try await store.load().vhosts.map(\.domain) == ["a.local"])

        hosts.fail(with: nil)
        #expect(await service.syncHosts() == .synced(.updated(via: .adminPrompt)))
    }

    @Test func unmanagedHostsFileIsNeverTouched() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.hosts.manageHostsFile = false }
        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/a"]))
        let result = try await service.add(Vhost(domain: "a.local", docroot: "/Users/tester/Sites/a"))
        #expect(result.hosts == .notManaged)
        #expect(await service.syncHosts() == .notManaged)
        #expect(hosts.calls.isEmpty)
    }

    @Test func concurrentChangesAreSerialized() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let docroots = (0..<8).map { "/Users/tester/Sites/s\($0)" }
        let service = VhostService(store: store, applier: FakeApplier(store: store), hosts: FakeHostsSync(channel: .helper),
                                   catalog: Self.catalog(env.paths, docroots: docroots))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask { try await service.add(Vhost(domain: "s\(i).local", docroot: docroots[i])) }
            }
            try await group.waitForAll()
        }
        #expect(try await store.load().vhosts.count == 8)
    }

    /// Real StackController + supervisor: a rejected config never reaches the running "Apache" and the
    /// generated vhost file is removed again; a good change reloads gracefully (same PID).
    @Test func stackControllerRollbackKeepsApacheRunningOnOldConfig() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let vhostsDir = env.paths.apacheVhostsDir.path(percentEncoded: false)
        let apache = ServiceSpec(id: .apache, executable: URL(filePath: "/bin/sh"),
                                 arguments: ["-c", "trap '' USR1 USR2; exec /bin/sleep 60"],
                                 stopTimeout: .seconds(3), reloadSignal: SIGUSR1,
                                 preflight: [["/bin/sh", "-c", "! /usr/bin/grep -rq BAD '\(vhostsDir)'"]])
        let renderer: StackController.Renderer = { config, paths in
            config.vhosts.filter(\.enabled).map {
                GeneratedFile(path: paths.apacheVhostsDir.appending(path: "\($0.domain).conf"),
                              contents: "DocumentRoot \($0.docroot)\n")
            }
        }
        let supervisor = ServiceSupervisor(paths: env.paths, cleanupOrphans: false)
        let stack = StackController(paths: env.paths, configStore: store, supervisor: supervisor,
                                    specProvider: { _, _ in [apache] }, renderer: renderer)
        try await stack.prepare()
        #expect(try await stack.startAll().succeeded)
        try await Task.sleep(for: .milliseconds(300))
        let pid = try #require(await stack.status()[.apache]?.pid)

        let hosts = FakeHostsSync(channel: .helper)
        let service = VhostService(store: store, applier: stack, hosts: hosts,
                                   catalog: Self.catalog(env.paths, docroots: ["/Users/tester/Sites/ok", "/Users/tester/Sites/BAD"]))
        try await service.add(Vhost(domain: "ok.local", docroot: "/Users/tester/Sites/ok"))
        await #expect(throws: VhostServiceError.self) {
            try await service.add(Vhost(domain: "broken.local", docroot: "/Users/tester/Sites/BAD"))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: vhostsDir)
        #expect(files == ["ok.local.conf"])
        #expect(try await store.load().vhosts.map(\.domain) == ["ok.local"])
        #expect(await stack.status()[.apache]?.pid == pid)
        #expect(await stack.status()[.apache]?.isRunning == true)
        #expect(hosts.calls == [["ok.local"]])
        await stack.stopAll()
    }
}
