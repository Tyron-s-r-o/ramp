import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// Per-service API used by the GUI (05-01). Lives in the serialized `StackControllerTests` suite.
extension StackControllerTests {
    @Test func startStopRestartSingleService() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update { $0.services["ramp-test-off"] = ServiceSettings(autostart: false) }
        let specs = [sleepSpec("ramp-test-one"), sleepSpec("ramp-test-off")]
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in specs }, renderer: { _, _ in [] })
        #expect(await controller.expectedServices() == [.custom("ramp-test-one")])

        let id = ServiceID.custom("ramp-test-one")
        let first = try #require(await controller.start(id).pid)
        #expect(isAlive(first))
        #expect(await controller.status()[.custom("ramp-test-off")] == .stopped)

        let second = try #require(try await controller.restart(id).pid)
        #expect(second != first)
        #expect(!isAlive(first))

        await controller.stop(id)
        #expect(await controller.status()[id] == .stopped)
        #expect(!isAlive(second))

        if case .failed = await controller.start(.custom("ramp-test-missing")) {} else {
            Issue.record("unknown service must fail")
        }
        await #expect(throws: SupervisorError.unknownService(.custom("ramp-test-missing"))) {
            try await controller.restart(.custom("ramp-test-missing"))
        }
        #expect(try await controller.currentConfig().services["ramp-test-off"]?.autostart == false)
    }

    @Test func reloadOnlyForReloadableServices() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let reloadable = ServiceSpec(id: .apache, executable: URL(filePath: "/bin/sh"),
                                     arguments: ["-c", "trap '' USR1; exec /bin/sleep 60"],
                                     stopTimeout: .seconds(3), reloadSignal: SIGUSR1)
        let plain = sleepSpec("ramp-test-plain")
        let controller = StackController(paths: env.paths,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [reloadable, plain] }, renderer: { _, _ in [] })
        _ = try await controller.startAll()
        let pid = try #require(await controller.status()[.apache]?.pid)
        try await controller.reload(.apache)
        #expect(await controller.status()[.apache]?.pid == pid)
        await #expect(throws: SupervisorError.notReloadable(.custom("ramp-test-plain"))) {
            try await controller.reload(.custom("ramp-test-plain"))
        }
        await controller.stopAll()
    }
}
