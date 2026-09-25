import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// Clock whose sleeps return immediately (backoff tests run instantly).
struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { .now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Temp RAMP root + logs (`ramp-test-*`), removed after the test.
struct TestEnv {
    let dir: URL
    let paths: Paths

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ramp-test-\(UUID().uuidString.prefix(8))",
                                                               directoryHint: .isDirectory)
        paths = Paths(root: dir.appending(path: "root", directoryHint: .isDirectory),
                      logs: dir.appending(path: "logs", directoryHint: .isDirectory))
        try paths.ensureDirectories()
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func log(_ name: String) -> String {
        (try? String(contentsOf: paths.log("\(name).log"), encoding: .utf8)) ?? ""
    }
}

/// Copies a system binary and ad-hoc re-signs it (a plain copy of a platform binary is SIGKILLed by AMFI).
func copySigned(_ source: String, to dest: URL) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(filePath: source), to: dest)
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/codesign")
    p.arguments = ["--force", "-s", "-", dest.path(percentEncoded: false)]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func sleepSpec(_ name: String, dependsOn: [ServiceID] = []) -> ServiceSpec {
    ServiceSpec(id: .custom(name), executable: URL(filePath: "/bin/sleep"), arguments: ["30"],
                stopTimeout: .seconds(3), dependsOn: dependsOn)
}

@Suite struct ServiceSupervisorTests {
    @Test func startRunningWritesPidFileAndStopLeavesNoProcess() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let sup = ServiceSupervisor(paths: env.paths)
        let state = await sup.start(sleepSpec("ramp-test-sleep"))
        let pid = try #require(state.pid)
        #expect(isAlive(pid))
        let pidFile = env.paths.pidFile(service: "ramp-test-sleep")
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "\(pid)\n")
        #expect(env.log("ramp-test-sleep").contains("=== RAMP started ramp-test-sleep pid \(pid) ==="))

        await sup.stop(.custom("ramp-test-sleep"))
        #expect(await sup.state(of: .custom("ramp-test-sleep")) == .stopped)
        #expect(!isAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
        // no restart after a requested stop
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sup.state(of: .custom("ramp-test-sleep")) == .stopped)
        let events = await sup.recentEvents
        #expect(!events.contains { if case .restartScheduled = $0 { return true } else { return false } })
        #expect(env.log("ramp-test-sleep").contains("exited ramp-test-sleep pid \(pid)"))
    }

    @Test func crashBacksOffWithIncreasingDelaysThenFails() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let sup = ServiceSupervisor(paths: env.paths, clock: ImmediateClock(),
                                    policy: BackoffPolicy(maxCrashes: 4))
        let id = ServiceID.custom("ramp-test-crash")
        await sup.start(ServiceSpec(id: id, executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exit 3"]))
        let failed = await eventually {
            if case .failed = await sup.state(of: id) { return true } else { return false }
        }
        #expect(failed)
        guard case .failed(let reason) = await sup.state(of: id) else { return }
        #expect(reason.contains("crashed 4 times"))
        let delays = await sup.recentEvents.compactMap { e -> Duration? in
            if case .restartScheduled(_, _, let d) = e { return d } else { return nil }
        }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4)])
        let exits = await sup.recentEvents.filter {
            if case .exited(_, _, 3, false, false) = $0 { return true } else { return false }
        }
        #expect(exits.count == 4)
        #expect(env.log("ramp-test-crash").contains("exit code 3 (unexpected)"))
    }

    @Test func stopDuringBackoffCancelsRestart() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        // Real clock, 1 s base delay: we stop while backing off.
        let sup = ServiceSupervisor(paths: env.paths)
        let id = ServiceID.custom("ramp-test-backoff")
        await sup.start(ServiceSpec(id: id, executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exit 1"]))
        #expect(await eventually {
            if case .backingOff(1, _) = await sup.state(of: id) { return true } else { return false }
        })
        await sup.stop(id)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(await sup.state(of: id) == .stopped)
    }

    @Test func reloadKeepsPidAndRunsHandler() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let marker = env.dir.appending(path: "reloaded.txt").path(percentEncoded: false)
        let script = "trap 'echo reloaded >> \"$1\"' USR1; while :; do sleep 0.05; done"
        let id = ServiceID.custom("ramp-test-reload")
        let sup = ServiceSupervisor(paths: env.paths)
        let state = await sup.start(ServiceSpec(id: id, executable: URL(filePath: "/bin/sh"),
                                                arguments: ["-c", script, "sh", marker],
                                                stopTimeout: .seconds(3), reloadSignal: SIGUSR1))
        let pid = try #require(state.pid)
        try await Task.sleep(for: .milliseconds(200)) // let sh install the trap
        try await sup.reload(id)
        #expect(await eventually { FileManager.default.fileExists(atPath: marker) })
        #expect(await sup.state(of: id).pid == pid)
        #expect(isAlive(pid))
        await sup.stop(id)
        #expect(!isAlive(pid))
        await #expect(throws: SupervisorError.notRunning(id)) { try await sup.reload(id) }
    }

    @Test func tcpReadinessWaitsForListener() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let port = try TestListener.freePort()
        let id = ServiceID.custom("ramp-test-nc")
        let sup = ServiceSupervisor(paths: env.paths)
        let state = await sup.start(ServiceSpec(
            id: id, executable: URL(filePath: "/usr/bin/nc"), arguments: ["-lk", "127.0.0.1", "\(port)"],
            ports: [port], readiness: .tcp(host: "127.0.0.1", port: port), readinessTimeout: .seconds(5)))
        let pid = try #require(state.pid)
        // macOS nc -k re-creates its listening socket after each connection → brief refusals; poll.
        #expect(await eventually { Readiness.tcp(host: "127.0.0.1", port: port).isReady() })
        await sup.stopAll()
        #expect(!isAlive(pid))
    }

    @Test func portConflictFailsWithActionableMessage() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let listener = try TestListener()
        defer { listener.close() }
        let sup = ServiceSupervisor(paths: env.paths)
        let clash = await sup.start(ServiceSpec(id: .redis, executable: URL(filePath: "/bin/sleep"),
                                                arguments: ["30"], ports: [listener.port]))
        if case .running = clash { await sup.stopAll() }
        guard case .failed(let reason) = clash else { Issue.record("expected failure, got \(clash)"); return }
        #expect(reason.contains("Port \(listener.port) is used by"))
        #expect(reason.contains("(PID \(getpid())"))
        #expect(reason.contains("change the Redis port in RAMP"))
    }

    @Test func readinessTimeoutKillsAndFails() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let port = try TestListener.freePort()
        let id = ServiceID.custom("ramp-test-notready")
        let sup = ServiceSupervisor(paths: env.paths)
        let state = await sup.start(ServiceSpec(id: id, executable: URL(filePath: "/bin/sleep"), arguments: ["30"],
                                                readiness: .tcp(host: "127.0.0.1", port: port),
                                                readinessTimeout: .milliseconds(400), stopTimeout: .seconds(2)))
        guard case .failed(let reason) = state else { Issue.record("expected failure, got \(state)"); return }
        #expect(reason.contains("did not become ready"))
        #expect(reason.contains("ramp-test-notready.log"))
        let pids = await sup.recentEvents.compactMap { e -> pid_t? in
            if case .exited(_, let pid, _, _, true) = e { return pid } else { return nil }
        }
        #expect(pids.count == 1)
        #expect(pids.allSatisfy { !isAlive($0) })
    }

    @Test func preflightFailureIsReported() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let sup = ServiceSupervisor(paths: env.paths)
        var spec = sleepSpec("ramp-test-preflight")
        spec.preflight = [["/bin/sh", "-c", "echo 'Syntax error on line 7' >&2; exit 1"]]
        let state = await sup.start(spec)
        #expect(state == .failed(reason: "ramp-test-preflight configuration test failed: Syntax error on line 7"))
    }

    @Test func stopAllRespectsReverseDependencyOrder() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let sup = ServiceSupervisor(paths: env.paths)
        let fpmA = ServiceID.custom("ramp-test-fpmA"), fpmB = ServiceID.custom("ramp-test-fpmB")
        let web = ServiceID.custom("ramp-test-web")
        await sup.start(sleepSpec("ramp-test-fpmA"))
        await sup.start(sleepSpec("ramp-test-fpmB"))
        await sup.start(sleepSpec("ramp-test-web", dependsOn: [fpmA, fpmB]))
        await sup.stopAll()
        let events = await sup.recentEvents
        func index(_ id: ServiceID, _ s: ServiceState) -> Int? {
            events.firstIndex(of: .stateChanged(id, s))
        }
        let webStopped = try #require(index(web, .stopped))
        let aStopping = try #require(index(fpmA, .stopping))
        let bStopping = try #require(index(fpmB, .stopping))
        #expect(webStopped < aStopping)
        #expect(webStopped < bStopping)
        for id in [fpmA, fpmB, web] { #expect(await sup.state(of: id) == .stopped) }
    }

    @Test func orphanUnderRootIsKilledForeignPidIsSpared() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let ourSleep = env.paths.root.appending(path: "bin/sleep")
        try copySigned("/bin/sleep", to: ourSleep)

        let orphan = Process()
        orphan.executableURL = ourSleep
        orphan.arguments = ["30"]
        try orphan.run()
        let foreign = Process()
        foreign.executableURL = URL(filePath: "/bin/sleep")
        foreign.arguments = ["30"]
        try foreign.run()
        defer { if foreign.isRunning { foreign.terminate() } ; if orphan.isRunning { orphan.terminate() } }

        try await Task.sleep(for: .milliseconds(100))
        #expect(orphan.isRunning && foreign.isRunning)
        #expect(PortProbe.executablePath(pid: orphan.processIdentifier)?.hasSuffix("/root/bin/sleep") == true)
        try "\(orphan.processIdentifier)\n".write(to: env.paths.pidFile(service: "ramp-test-orphan"),
                                                  atomically: true, encoding: .utf8)
        try "\(foreign.processIdentifier)\n".write(to: env.paths.pidFile(service: "ramp-test-foreign"),
                                                   atomically: true, encoding: .utf8)
        _ = ServiceSupervisor(paths: env.paths) // cleans up in init
        #expect(await eventually { !orphan.isRunning })
        #expect(foreign.isRunning)
        let left = try fm.contentsOfDirectory(atPath: env.paths.supervisorRunDir.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test func ownOrphanHoldingPortIsKilledBeforeStart() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let ourNC = env.paths.root.appending(path: "bin/nc")
        try copySigned("/usr/bin/nc", to: ourNC)
        let port = try TestListener.freePort()
        let orphan = Process()
        orphan.executableURL = ourNC
        orphan.arguments = ["-lk", "127.0.0.1", "\(port)"]
        orphan.standardError = FileHandle.nullDevice
        try orphan.run()
        defer { if orphan.isRunning { orphan.terminate() } }
        #expect(await eventually { Readiness.tcp(host: "127.0.0.1", port: port).isReady() })

        let sup = ServiceSupervisor(paths: env.paths)
        let state = await sup.start(ServiceSpec(id: .custom("ramp-test-takeover"), executable: URL(filePath: "/bin/sleep"),
                                                arguments: ["30"], ports: [port], stopTimeout: .seconds(2)))
        #expect(state.isRunning)
        #expect(await eventually { !orphan.isRunning })
        await sup.stopAll()
    }
}
