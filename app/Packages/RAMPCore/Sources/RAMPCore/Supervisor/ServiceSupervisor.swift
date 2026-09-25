import Darwin
import Foundation

/// Runs services as supervised child processes: port probe, preflight, spawn with log capture,
/// pid file, readiness wait, graceful reload, exponential-backoff restart, orderly stop.
///
/// Concurrency: `Process` and `FileHandle` never leave the actor. Each `Process.terminationHandler`
/// only captures Sendable values and hops back with `Task { await self.handleExit(...) }`.
public actor ServiceSupervisor {
    public nonisolated let events: AsyncStream<ServiceEvent>
    private let eventContinuation: AsyncStream<ServiceEvent>.Continuation

    public let paths: Paths
    private let clock: any Clock<Duration>
    private let policy: BackoffPolicy
    private let logSink: LogSink
    private var entries: [ServiceID: Entry] = [:]
    /// Last events (diagnostics + tests).
    private(set) var recentEvents: [ServiceEvent] = []

    /// Per-service bookkeeping. Actor-confined (never escapes), hence no Sendable requirement.
    private final class Entry {
        var spec: ServiceSpec
        var state: ServiceState = .stopped
        var tracker: BackoffTracker
        var process: Process?
        var pid: pid_t = 0
        var log: FileHandle?
        var startedAt: ContinuousClock.Instant = .now
        /// Incremented per spawn; stale exit handlers / backoff timers compare against it.
        var generation = 0
        var stopRequested = false
        var exited = true
        var backoffTask: Task<Void, Never>?

        init(spec: ServiceSpec, policy: BackoffPolicy) {
            self.spec = spec
            self.tracker = BackoffTracker(policy: policy)
        }
    }

    /// - Parameter clock: used for backoff delays only (tests inject an immediate clock).
    /// - Parameter cleanupOrphans: kill leftover RAMP processes from `run/supervisor/*.pid` (blocking,
    ///   bounded by a few seconds) before anything is started.
    public init(paths: Paths, clock: any Clock<Duration> = ContinuousClock(), policy: BackoffPolicy = .standard,
                logSink: LogSink? = nil, cleanupOrphans: Bool = true) {
        self.paths = paths
        self.clock = clock
        self.policy = policy
        self.logSink = logSink ?? LogSink(paths: paths)
        (events, eventContinuation) = AsyncStream.makeStream(of: ServiceEvent.self, bufferingPolicy: .bufferingNewest(1000))
        if cleanupOrphans { Self.cleanupOrphans(paths: paths) }
    }

    deinit { eventContinuation.finish() }

    // MARK: Public API

    public func state(of id: ServiceID) -> ServiceState { entries[id]?.state ?? .stopped }

    public func spec(of id: ServiceID) -> ServiceSpec? { entries[id]?.spec }

    /// Every service that was ever started (stopped ones stay registered).
    public func registeredIDs() -> Set<ServiceID> { Set(entries.keys) }

    /// Starts (or re-registers and starts) a service. Returns the state after readiness / failure.
    /// Already running or starting → no-op.
    @discardableResult
    public func start(_ spec: ServiceSpec) async -> ServiceState {
        let entry: Entry
        if let existing = entries[spec.id] {
            switch existing.state {
            case .running, .starting, .stopping: return existing.state
            default: break
            }
            existing.backoffTask?.cancel()
            existing.spec = spec
            entry = existing
        } else {
            entry = Entry(spec: spec, policy: policy)
            entries[spec.id] = entry
        }
        entry.tracker.reset()
        return await launch(entry)
    }

    /// Requested stop: stopSignal, wait `stopTimeout`, then SIGKILL. Never triggers a restart.
    public func stop(_ id: ServiceID) async {
        guard let entry = entries[id] else { return }
        entry.backoffTask?.cancel()
        entry.backoffTask = nil
        entry.stopRequested = true
        guard !entry.exited, entry.pid > 0 else {
            if entry.state != .stopped { setState(entry, .stopped) }
            return
        }
        setState(entry, .stopping)
        await terminate(entry)
    }

    /// Stop + start with the stored spec (backoff history cleared).
    @discardableResult
    public func restart(_ id: ServiceID) async throws -> ServiceState {
        guard let entry = entries[id] else { throw SupervisorError.unknownService(id) }
        await stop(id)
        entry.tracker.reset()
        return await launch(entry)
    }

    /// Sends the reload signal to the tracked master PID; state and PID stay unchanged.
    public func reload(_ id: ServiceID) throws {
        guard let entry = entries[id] else { throw SupervisorError.unknownService(id) }
        guard case .running(let pid, _) = entry.state else { throw SupervisorError.notRunning(id) }
        guard let sig = entry.spec.reloadSignal else { throw SupervisorError.notReloadable(id) }
        guard kill(pid, sig) == 0 else { throw SupervisorError.signalFailed(id, errno: errno) }
        if let log = entry.log { LogSink.marker(log, "reload \(id.name) pid \(pid) signal \(sig)") }
        emit(.reloaded(id, pid: pid))
    }

    /// Stops everything in reverse dependency order: a service stops only after every service that
    /// depends on it has stopped; independent services stop concurrently.
    public func stopAll() async {
        var remaining = Set(entries.keys)
        while !remaining.isEmpty {
            let layer = remaining.filter { candidate in
                !remaining.contains { other in
                    other != candidate && (entries[other]?.spec.dependsOn.contains(candidate) ?? false)
                }
            }
            // Dependency cycle safety net: stop the rest together.
            let batch = layer.isEmpty ? remaining : layer
            await withTaskGroup(of: Void.self) { group in
                for id in batch { group.addTask { await self.stop(id) } }
            }
            remaining.subtract(batch)
        }
    }

    // MARK: Launch

    private func launch(_ entry: Entry) async -> ServiceState {
        let spec = entry.spec
        let id = spec.id
        entry.generation += 1
        let generation = entry.generation
        entry.stopRequested = false
        setState(entry, .starting)

        // 1. Ports
        for port in spec.ports {
            switch PortProbe.check(port: port, addresses: spec.listenAddresses, ownRoot: paths.root,
                                   serviceName: id.displayName) {
            case .free:
                continue
            case .ownOrphan(let pid, let exe):
                appendLog(entry, "killing orphaned RAMP process \(pid) (\(exe)) holding port \(port)")
                Self.terminateForeign(pid: pid, timeout: spec.stopTimeout)
            case .inUse(let conflict):
                return fail(entry, conflict.description)
            }
        }

        // 2. Preflight config tests
        for argv in spec.preflight where !argv.isEmpty {
            let (status, output) = Self.runCaptured(argv, environment: spec.resolvedEnvironment(),
                                                    cwd: spec.workingDirectory)
            if status != 0 {
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                appendLog(entry, "preflight failed (\(argv.joined(separator: " "))): \(text)")
                return fail(entry, "\(id.displayName) configuration test failed: \(text.isEmpty ? "exit \(status)" : text)")
            }
        }
        guard entry.generation == generation, !entry.stopRequested else { return entry.state }

        // 3. Stale unix sockets (ours only) would make readiness lie or the bind fail.
        for socket in spec.readiness.unixSockets
        where PortProbe.isUnder(socket.path(percentEncoded: false), root: paths.root)
            && FileManager.default.fileExists(atPath: socket.path(percentEncoded: false))
            && !SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: socket)
        }

        // 4. Spawn
        let log: FileHandle
        do { log = try logSink.open(service: id.name) } catch {
            return fail(entry, "Cannot open log \(logSink.url(service: id.name).path(percentEncoded: false)): \(error)")
        }
        entry.log = log
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.resolvedEnvironment()
        if let cwd = spec.workingDirectory { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] p in
            let pid = p.processIdentifier
            let status = p.terminationStatus
            let signaled = p.terminationReason == .uncaughtSignal
            Task { await self?.handleExit(id: id, generation: generation, pid: pid, status: status, signaled: signaled) }
        }
        do {
            try process.run()
        } catch {
            appendLog(entry, "spawn failed: \(error.localizedDescription)")
            return fail(entry, "Cannot start \(id.displayName): \(error.localizedDescription)")
        }
        entry.process = process
        entry.pid = process.processIdentifier
        entry.exited = false
        entry.startedAt = .now
        LogSink.marker(log, "started \(id.name) pid \(entry.pid)")
        writePidFile(id: id, pid: entry.pid)

        // 5. Readiness
        let deadline = ContinuousClock.now + spec.readinessTimeout
        while !spec.readiness.isReady() {
            if entry.generation != generation || entry.exited || entry.stopRequested { return entry.state }
            if ContinuousClock.now >= deadline {
                let logPath = logSink.url(service: id.name).path(percentEncoded: false)
                appendLog(entry, "did not become ready within \(spec.readinessTimeout), stopping")
                entry.stopRequested = true
                await terminate(entry)
                return fail(entry, "\(id.displayName) did not become ready within \(spec.readinessTimeout), see \(logPath)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard entry.generation == generation, !entry.exited, !entry.stopRequested else { return entry.state }
        setState(entry, .running(pid: entry.pid, since: .now))
        return entry.state
    }

    // MARK: Exit handling

    private func handleExit(id: ServiceID, generation: Int, pid: pid_t, status: Int32, signaled: Bool) {
        guard let entry = entries[id], entry.generation == generation, !entry.exited else { return }
        entry.exited = true
        // Children orphaned by the master's death (php-fpm workers after kill -9 keep the listen socket
        // and make the restarted master fail with "Another FPM instance seems to already listen").
        Self.killProcessGroup(of: pid)
        entry.process = nil
        removePidFile(id: id, pid: pid)
        let how = signaled ? "signal \(status)" : "exit code \(status)"
        if let log = entry.log {
            LogSink.marker(log, "exited \(id.name) pid \(pid) \(how)\(entry.stopRequested ? "" : " (unexpected)")")
        }
        entry.log = nil
        emit(.exited(id, pid: pid, status: status, signal: signaled, requested: entry.stopRequested))

        if entry.stopRequested {
            if case .failed = entry.state { return }
            setState(entry, .stopped)
            return
        }
        switch entry.tracker.recordCrash(startedAt: entry.startedAt, exitedAt: .now) {
        case .giveUp(let crashes):
            _ = fail(entry, "\(id.displayName) crashed \(crashes) times within \(policy.window) (last: \(how)); "
                     + "see \(logSink.url(service: id.name).path(percentEncoded: false))")
        case .restart(let delay, let attempt):
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            setState(entry, .backingOff(attempt: attempt, until: Date.now.addingTimeInterval(seconds)))
            emit(.restartScheduled(id, attempt: attempt, delay: delay))
            if let log = try? logSink.open(service: id.name) {
                LogSink.marker(log, "restarting \(id.name) in \(delay) (attempt \(attempt))")
            }
            let clock = self.clock
            entry.backoffTask = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                await self?.resumeAfterBackoff(id: id, generation: generation)
            }
        }
    }

    private func resumeAfterBackoff(id: ServiceID, generation: Int) async {
        guard let entry = entries[id], entry.generation == generation,
              case .backingOff = entry.state else { return }
        entry.backoffTask = nil
        _ = await launch(entry)
    }

    // MARK: Termination

    /// Sends stopSignal, waits stopTimeout, then SIGKILL; returns once the exit was handled.
    private func terminate(_ entry: Entry) async {
        guard !entry.exited, entry.pid > 0 else { return }
        let pid = entry.pid
        if let log = entry.log { LogSink.marker(log, "stopping \(entry.spec.id.name) pid \(pid) signal \(entry.spec.stopSignal)") }
        kill(pid, entry.spec.stopSignal)
        if await waitForExit(entry, timeout: entry.spec.stopTimeout) { return }
        if let log = entry.log { LogSink.marker(log, "\(entry.spec.id.name) pid \(pid) ignored stop signal, SIGKILL") }
        kill(pid, SIGKILL)
        _ = await waitForExit(entry, timeout: .seconds(5))
    }

    private func waitForExit(_ entry: Entry, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entry.exited {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// SIGTERM → wait → SIGKILL for a process that is not our child (orphan from a previous run).
    static func terminateForeign(pid: pid_t, timeout: Duration) {
        guard pid > 1 else { return }
        kill(pid, SIGTERM)
        let deadline = ContinuousClock.now + timeout
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline { usleep(20_000) }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            let hard = ContinuousClock.now + .seconds(2)
            while kill(pid, 0) == 0 && ContinuousClock.now < hard { usleep(20_000) }
        }
    }

    /// Every service is spawned as its own process-group leader (Foundation `Process`: pgid == pid).
    /// After the leader exited, SIGKILL whatever is left in that group. Never our own group; a group id
    /// without members yields ESRCH (no-op).
    static func killProcessGroup(of pid: pid_t) {
        guard pid > 1, pid != getpgrp() else { return }
        killpg(pid, SIGKILL)
    }

    // MARK: Orphans

    /// For every `run/supervisor/*.pid`: if the PID is alive and its executable lies under
    /// `Paths.root`, terminate it (SIGTERM, wait, SIGKILL). The pid file is removed in every case.
    /// A PID whose executable is outside our root is never touched (PID reuse safety).
    @discardableResult
    public static func cleanupOrphans(paths: Paths, timeout: Duration = .seconds(5)) -> [pid_t] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: paths.supervisorRunDir, includingPropertiesForKeys: nil)
        else { return [] }
        var killed: [pid_t] = []
        for file in files where file.pathExtension == "pid" {
            defer { try? fm.removeItem(at: file) }
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  kill(pid, 0) == 0,
                  let exe = PortProbe.executablePath(pid: pid),
                  PortProbe.isUnder(exe, root: paths.root) else { continue }
            terminateForeign(pid: pid, timeout: timeout)
            killed.append(pid)
        }
        return killed
    }

    // MARK: Helpers

    private func setState(_ entry: Entry, _ state: ServiceState) {
        entry.state = state
        emit(.stateChanged(entry.spec.id, state))
    }

    private func fail(_ entry: Entry, _ reason: String) -> ServiceState {
        setState(entry, .failed(reason: reason))
        return entry.state
    }

    private func emit(_ event: ServiceEvent) {
        recentEvents.append(event)
        if recentEvents.count > 500 { recentEvents.removeFirst(recentEvents.count - 500) }
        eventContinuation.yield(event)
    }

    private func appendLog(_ entry: Entry, _ text: String) {
        if let log = entry.log {
            LogSink.marker(log, text)
        } else if let log = try? logSink.open(service: entry.spec.id.name) {
            LogSink.marker(log, text)
        }
    }

    private func writePidFile(id: ServiceID, pid: pid_t) {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.supervisorRunDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? Data("\(pid)\n".utf8).write(to: paths.pidFile(service: id.name), options: .atomic)
    }

    /// Removes the pid file only if it still names `pid` (a newer run may have rewritten it).
    private func removePidFile(id: ServiceID, pid: pid_t) {
        let url = paths.pidFile(service: id.name)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == pid {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Runs a short command synchronously, returning exit status and combined stdout+stderr.
    static func runCaptured(_ argv: [String], environment: [String: String], cwd: URL?) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(filePath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "cannot run \(argv[0]): \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
