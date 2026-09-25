import Darwin
import Foundation
import Testing
@testable import RAMPCore

private func fakeFPMSpec(_ branch: String) -> ServiceSpec {
    ServiceSpec(id: .phpFPM(branch), executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' USR1 USR2; exec /bin/sleep 60"],
                stopTimeout: .seconds(3), reloadSignal: SIGUSR2)
}

/// Service-set diff of `applyConfigChanges` (PHP branch disabled → its FPM stops, re-enabled → starts).
extension StackControllerTests {
    @Test func serviceSetChangesPureDiff() {
        let a = ServiceID.phpFPM("8.2"), b = ServiceID.phpFPM("8.3"), apache = ServiceID.apache
        let es = ServiceID.elasticsearch
        // Removed from the set → stop; nothing started.
        var d = StackController.serviceSetChanges(previous: [a, b, apache], next: [a, apache],
                                                  registered: [a, b, apache], running: [a, b, apache],
                                                  autostart: [a, apache])
        #expect(d.stop == [b] && d.start.isEmpty)
        // Re-added while still registered (stopped) → start; untouched others stay.
        d = StackController.serviceSetChanges(previous: [a, apache], next: [a, b, apache],
                                              registered: [a, b, apache], running: [a, apache],
                                              autostart: [a, b, apache])
        #expect(d.stop.isEmpty && d.start == [b])
        // A service the user stopped by hand (still in the set) is never restarted.
        d = StackController.serviceSetChanges(previous: [a, b, apache], next: [a, b, apache],
                                              registered: [a, b, apache], running: [a, apache],
                                              autostart: [a, b, apache])
        #expect(d.stop.isEmpty && d.start.isEmpty)
        // New, never registered + autostart → start; autostart false → not started.
        d = StackController.serviceSetChanges(previous: [a], next: [a, b, apache], registered: [a],
                                              running: [a], autostart: [a, b])
        #expect(d.start == [b])
        // Unknown previous set (fresh controller): a running FPM no longer configured is stopped,
        // registered-but-stopped services are not started, non-FPM extras (Elasticsearch) are left alone.
        d = StackController.serviceSetChanges(previous: [], next: [a, apache], registered: [a, b, apache, es],
                                              running: [a, b, es], autostart: [a, apache])
        #expect(d.stop == [b] && d.start.isEmpty)
    }

    @Test func disablingABranchStopsOnlyItsFPMAndEnablingStartsIt() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let provider: StackController.SpecProvider = { config, _ in
            ["8.2", "8.3"].filter { config.php.branches[$0]?.enabled ?? true }.map(fakeFPMSpec) + [sleepSpec("ramp-test-web")]
        }
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: provider, renderer: { _, _ in [] })
        #expect(try await controller.startAll().succeeded)
        let before = await controller.status().mapValues(\.pid)

        try await store.update { $0.php.branches["8.3"] = PHPBranchSettings(enabled: false) }
        let off = try await controller.applyConfigChanges()
        #expect(off.stopped == [.phpFPM("8.3")] && off.started.isEmpty && off.errors.isEmpty)
        #expect(await controller.status()[.phpFPM("8.3")] == nil)
        #expect(!isAlive(try #require(before[.phpFPM("8.3")] ?? nil)))
        #expect(await controller.expectedServices() == [.phpFPM("8.2"), .custom("ramp-test-web")])

        try await store.update { $0.php.branches["8.3"] = nil }
        let on = try await controller.applyConfigChanges()
        #expect(on.started == [.phpFPM("8.3")] && on.stopped.isEmpty && on.errors.isEmpty)
        let after = await controller.status()
        #expect(after[.phpFPM("8.3")]?.isRunning == true)
        // Other services keep their PIDs across both changes.
        #expect(after[.phpFPM("8.2")]?.pid == before[.phpFPM("8.2")] ?? nil)
        #expect(after[.custom("ramp-test-web")]?.pid == before[.custom("ramp-test-web")] ?? nil)
        await controller.stopAll()
    }
}
