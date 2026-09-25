import Darwin
import Foundation
import RAMPCore

// rampctl es … (plan 06-03). Elasticsearch is supervised by the long-running `rampctl up` (never autostarted):
// start/stop/restart/apply are handed to it through a request file in `run/es-requests/` + SIGUSR1, and the
// command waits for the response file. Without a running `up`, `es start` supervises ES in the foreground
// until SIGINT/SIGTERM. Errors print the LocalizedError text and exit 2.
//
//   rampctl es install [--manifest <url|path>]
//   rampctl es start | stop | restart | status
//   rampctl es heap <size>                        e.g. 512m, 2g (restart when running)
//   rampctl es plugin list | install <name> | remove <name>
//   rampctl es postpone [hours]                   push the auto-stop by N h (default 1; needs `rampctl up`)
//   rampctl es autostop [--after <h|off>] [--at <HH:mm|off>]   (06-04; validated, applies on the next tick)
//
// Auto-stop (06-04): `rampctl up` (and a foreground `es start`) runs `ElasticsearchAutoStopScheduler`; its session
// is persisted in `run/es-autostop.json` for `es status`. Test aid: `RAMP_ES_AUTOSTOP_SECONDS=<n>` in the
// environment of `rampctl up` / `es status` replaces the configured rules by "stop n seconds after start"
// (the app ignores it).

let esUsageText = """
       rampctl es install [--manifest <url|path>]
       rampctl es start | stop | restart | status
       rampctl es heap <size>
       rampctl es plugin list | install <name> | remove <name>
       rampctl es postpone [hours]
       rampctl es autostop [--after <h|off>] [--at <HH:mm|off>]
"""

private struct ESUsageError: Error {}

private struct ESFailure: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private func esOut(_ s: String) { print(s); fflush(stdout) }
private func esErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private func esMessage(_ error: any Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}

private func esDescribe(_ state: ServiceState) -> String {
    switch state {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .running(let pid, _): return "running (pid \(pid))"
    case .stopping: return "stopping"
    case .backingOff(let attempt, _): return "restarting (attempt \(attempt))"
    case .failed(let reason): return "FAILED: \(reason)"
    }
}

private func esLivePid(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
    else { return nil }
    return pid
}

private func esUpPid(_ paths: Paths) -> pid_t? {
    esLivePid(paths.runDir.appending(path: "rampctl.pid", directoryHint: .notDirectory))
}

private func esRequestDir(_ paths: Paths) -> URL {
    paths.runDir.appending(path: "es-requests", directoryHint: .isDirectory)
}

/// Service in a process that does NOT supervise ES (no orphan cleanup of a live stack).
private func detachedService(_ paths: Paths) -> ElasticsearchService {
    let stack = StackController(paths: paths, supervisor: ServiceSupervisor(paths: paths, cleanupOrphans: false))
    return ElasticsearchService(stack: stack)
}

// MARK: Request channel (client side)

private struct ESResponse: Codable {
    var code: Int32
    var message: String
}

/// Hands `action` to the running `rampctl up` and waits for its answer.
private func esRequest(_ action: String, paths: Paths, upPid: pid_t, timeout: Duration = .seconds(240)) async throws -> ESResponse {
    let fm = FileManager.default
    let dir = esRequestDir(paths)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID().uuidString
    let req = dir.appending(path: "\(id).req", directoryHint: .notDirectory)
    let res = dir.appending(path: "\(id).res", directoryHint: .notDirectory)
    try Data(action.utf8).write(to: req, options: .atomic)
    guard kill(upPid, SIGUSR1) == 0 else {
        try? fm.removeItem(at: req)
        throw ESFailure(text: "cannot signal rampctl up (pid \(upPid))")
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let data = try? Data(contentsOf: res), let response = try? JSONDecoder().decode(ESResponse.self, from: data) {
            try? fm.removeItem(at: res)
            return response
        }
        if kill(upPid, 0) != 0 { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    try? fm.removeItem(at: req)
    throw ESFailure(text: "rampctl up (pid \(upPid)) did not answer the \(action) request")
}

// MARK: Request channel (server side, inside `rampctl up`)

/// Serves `run/es-requests/*.req` for `rampctl up`; `wake()` on SIGUSR1. Requests run one at a time.
final class ESRequestWorker: Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>

    init(controller: StackController, paths: Paths, service: ElasticsearchService? = nil,
         autoStop: ElasticsearchAutoStopScheduler? = nil) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        let service = service ?? ElasticsearchService(stack: controller)
        task = Task {
            for await _ in stream {
                await Self.drain(service: service, controller: controller, paths: paths, autoStop: autoStop)
            }
        }
        continuation.yield()   // requests left from before start
    }

    func wake() { continuation.yield() }

    func cancel() {
        continuation.finish()
        task.cancel()
    }

    private static func drain(service: ElasticsearchService, controller: StackController, paths: Paths,
                              autoStop: ElasticsearchAutoStopScheduler?) async {
        let fm = FileManager.default
        let dir = esRequestDir(paths)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".req") }.sorted()
        for name in names {
            let req = dir.appending(path: name, directoryHint: .notDirectory)
            guard let action = try? String(contentsOf: req, encoding: .utf8) else { continue }
            try? fm.removeItem(at: req)
            let response = await handle(action.trimmingCharacters(in: .whitespacesAndNewlines),
                                        service: service, controller: controller, autoStop: autoStop)
            esOut("[elasticsearch] request \(action): \(response.message)")
            let res = dir.appending(path: String(name.dropLast(4)) + ".res", directoryHint: .notDirectory)
            if let data = try? JSONEncoder().encode(response) { try? data.write(to: res, options: .atomic) }
        }
    }

    private static func handle(_ action: String, service: ElasticsearchService, controller: StackController,
                               autoStop: ElasticsearchAutoStopScheduler?) async -> ESResponse {
        func stateResponse(_ state: ServiceState) async -> ESResponse {
            // Requested start: new auto-stop session (a restart keeps the running one).
            if state.isRunning, let autoStop { await autoStop.sessionStarted(at: Date()) }
            return ESResponse(code: state.isRunning ? 0 : 2, message: esDescribe(state))
        }
        do {
            switch action {
            case "start": return await stateResponse(try await service.start())
            case "restart": return await stateResponse(try await service.restart())
            case "stop":
                await service.stop()
                await autoStop?.sessionEnded()
                return ESResponse(code: 0, message: esDescribe(await service.state()))
            case let postpone where postpone.hasPrefix("postpone "):
                guard let autoStop, let hours = Int(postpone.dropFirst("postpone ".count)), (1...24).contains(hours)
                else { return ESResponse(code: 2, message: "invalid postpone request") }
                guard await service.state().isRunning else {
                    return ESResponse(code: 2, message: "Elasticsearch is not running")
                }
                let status = await autoStop.postpone(now: Date(), by: .seconds(hours * 3600))
                guard status.deadline != nil else { return ESResponse(code: 2, message: "auto-stop: vypnutý") }
                return ESResponse(code: 0, message: status.cliDescription())
            case "apply":
                let report = try await controller.applyConfigChanges()
                if let error = report.errors[.elasticsearch] { return ESResponse(code: 2, message: error) }
                let state = await service.state()
                let restarted = report.restarted.contains(.elasticsearch)
                return ESResponse(code: 0, message: (restarted ? "restarted, " : "") + esDescribe(state))
            default:
                return ESResponse(code: 2, message: "unknown request \(action)")
            }
        } catch {
            return ESResponse(code: 2, message: esMessage(error))
        }
    }
}

// MARK: Commands

/// Entry point for `rampctl es …`.
func esCommand(_ args: [String]) async -> Int32 {
    let paths = Paths.standard()
    do {
        guard let sub = args.first else { throw ESUsageError() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "install": return try await esInstall(rest, paths: paths)
        case "start", "stop", "restart":
            guard rest.isEmpty else { throw ESUsageError() }
            return try await esLifecycle(sub, paths: paths)
        case "status":
            guard rest.isEmpty else { throw ESUsageError() }
            return try await esStatus(paths: paths)
        case "heap":
            guard rest.count == 1 else { throw ESUsageError() }
            return try await esHeap(rest[0], paths: paths)
        case "plugin":
            return try await esPlugin(rest, paths: paths)
        case "postpone":
            guard rest.count <= 1 else { throw ESUsageError() }
            return try await esPostpone(rest.first, paths: paths)
        case "autostop":
            return try await esAutoStop(rest, paths: paths)
        default: throw ESUsageError()
        }
    } catch is ESUsageError {
        esErr("usage:\n" + esUsageText)
        return 64
    } catch {
        esErr("error: \(esMessage(error))")
        return 2
    }
}

private func esInstall(_ args: [String], paths: Paths) async throws -> Int32 {
    var manifest: Manifest?
    if !args.isEmpty {
        guard args.count == 2, args[0] == "--manifest" else { throw ESUsageError() }
        let raw = args[1]
        let url: URL
        if let u = URL(string: raw), let scheme = u.scheme, scheme == "file" || scheme == "https" {
            url = u
        } else {
            let path = (raw as NSString).expandingTildeInPath
            url = URL(filePath: path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path)
                .standardizedFileURL
        }
        manifest = try await ManifestLoader.load(url)
    }
    try paths.ensureDirectories()
    let installer = PackageInstaller(paths: paths, configStore: ConfigStore(paths: paths))
    let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
    let printer = Task {
        for await p in progress {
            switch p.stage {
            case .downloading where p.download == nil: esOut("\(p.component) \(p.branch): downloading…")
            case .verifying: esOut("\(p.component) \(p.branch): verifying checksum…")
            case .extracting: esOut("\(p.component) \(p.branch): extracting…")
            case .activating: esOut("\(p.component) \(p.branch): activating…")
            case .installed(let pkg): esOut("\(p.component) \(p.branch): installed \(pkg.version)")
            case .failed, .downloading: break
            }
        }
    }
    let started = ContinuousClock.now
    let record = try await installer.installElasticsearch(manifest: manifest, progress: continuation)
    await printer.value
    esOut("elasticsearch \(record.version) ready (\(ContinuousClock.now - started)); start it with: rampctl es start")
    return 0
}

private func esLifecycle(_ action: String, paths: Paths) async throws -> Int32 {
    if let upPid = esUpPid(paths) {
        let response = try await esRequest(action, paths: paths, upPid: upPid)
        if response.code == 0 { esOut("elasticsearch: \(response.message)") } else { esErr("error: \(response.message)") }
        return response.code
    }
    switch action {
    case "stop":
        esOut("elasticsearch: not running (rampctl up is not running)")
        return 0
    case "restart":
        throw ESFailure(text: "rampctl up is not running (use `rampctl es start` to run Elasticsearch in the foreground)")
    default:
        return await esForeground(paths: paths)
    }
}

/// `es start` without `rampctl up`: supervise ES here until SIGINT/SIGTERM.
private func esForeground(paths: Paths) async -> Int32 {
    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let (signals, continuation) = AsyncStream<Int32>.makeStream()
    let queue = DispatchQueue(label: "rampctl.es.signals")
    let sources = [SIGINT, SIGTERM].map { sig -> any DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler { continuation.yield(sig) }
        src.resume()
        return src
    }
    let service = detachedService(paths)
    do {
        let state = try await service.start()
        guard state.isRunning else {
            esErr("error: \(esDescribe(state))")
            await service.stop()
            return 2
        }
        esOut("elasticsearch: \(esDescribe(state)) — foreground, Ctrl-C stops it")
    } catch {
        esErr("error: \(esMessage(error))")
        return 2
    }
    // Auto-stop here too; once ES is stopped by it, leave the foreground loop.
    let autoStop = esMakeAutoStop(service: service, paths: paths)
    await autoStop.sessionStarted(at: Date())
    let autoStopTask = Task { await autoStop.run() }
    let watcher = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            switch await service.state() {
            case .stopped, .failed:
                continuation.yield(0)
                return
            default: continue
            }
        }
    }
    for await _ in signals { break }
    watcher.cancel()
    autoStopTask.cancel()
    await service.stop()
    await autoStop.sessionEnded()
    sources.forEach { $0.cancel() }
    esOut("elasticsearch: stopped")
    return 0
}

private func esStatus(paths: Paths) async throws -> Int32 {
    let config = try await ConfigStore(paths: paths).load()
    let es = config.elasticsearch
    guard let record = config.installed["elasticsearch"]?[es.branch] else {
        esOut("elasticsearch \(es.branch): not installed (rampctl es install)")
        return 3
    }
    let pid = esLivePid(paths.pidFile(service: ServiceID.elasticsearch.name))
    esOut("elasticsearch \(record.version) (branch \(es.branch)): " + (pid.map { "running (pid \($0))" } ?? "stopped"))
    esOut("  heap:    \(es.heap) (Xms = Xmx)")
    esOut("  ports:   http \(es.bindAddress):\(es.httpPort), transport \(es.transportPort)")
    let data = paths.elasticsearchData(branch: es.branch)
    esOut("  data:    \(data.path(percentEncoded: false)) (\(esSize(data)))")
    let desired = es.plugins.isEmpty ? "none" : es.plugins.joined(separator: ", ")
    esOut("  plugins: \(desired) (desired)")
    if let installed = try? await detachedService(paths).plugins.list() {
        esOut("           \(installed.isEmpty ? "none" : installed.joined(separator: ", ")) (installed)")
    }
    esOut("  " + esAutoStopLine(settings: es.autoStop, running: pid != nil, paths: paths))
    esOut("  up:      " + (esUpPid(paths).map { "rampctl up pid \($0)" } ?? "rampctl up not running"))
    return pid == nil ? 3 : 0
}

// MARK: Auto-stop (06-04)

/// Scheduler used by `rampctl up` and a foreground `es start` (settings re-read from ramp.json on every tick).
func esMakeAutoStop(service: ElasticsearchService, paths: Paths) -> ElasticsearchAutoStopScheduler {
    let store = ConfigStore(paths: paths)   // read-only; ramp.json is re-read on every tick
    return ElasticsearchAutoStopScheduler(
        es: service,
        settings: { (try? await store.load())?.elasticsearch.autoStop ?? AutoStopSettings() },
        log: LogSink(paths: paths),
        stateFile: ElasticsearchAutoStopScheduler.stateFile(paths: paths),
        overrideAfterSeconds: ElasticsearchAutoStopScheduler.overrideFromEnvironment())
}

/// `"auto-stop: o 01:00 (po 6 h) — zostáva 4 h 12 min"` while running (session from `run/es-autostop.json`),
/// otherwise the configured rules.
private func esAutoStopLine(settings: AutoStopSettings, running: Bool, paths: Paths) -> String {
    let override = ElasticsearchAutoStopScheduler.overrideFromEnvironment()
    if running {
        guard let persisted = ElasticsearchAutoStopScheduler.loadPersisted(
            from: ElasticsearchAutoStopScheduler.stateFile(paths: paths)) else {
            return "auto-stop: neznámy (ES nespustil rampctl up)"
        }
        return ElasticsearchAutoStopScheduler.status(
            now: Date(), sessionStart: persisted.sessionStart, postponedUntil: persisted.postponedUntil,
            settings: settings, calendar: .autoupdatingCurrent, overrideAfterSeconds: override).cliDescription()
    }
    if let override { return "auto-stop: po \(Int(override)) s (\(ElasticsearchAutoStopScheduler.overrideEnvironmentKey))" }
    return "auto-stop: " + esAutoStopRules(settings)
}

private func esAutoStopRules(_ settings: AutoStopSettings) -> String {
    var rules: [String] = []
    if let h = settings.afterHours { rules.append("po \(h) h") }
    if let t = settings.atTime { rules.append("o \(t)") }
    return rules.isEmpty ? "vypnutý" : rules.joined(separator: ", ")
}

private func esPostpone(_ raw: String?, paths: Paths) async throws -> Int32 {
    let hours: Int
    if let raw {
        guard let h = Int(raw), (1...24).contains(h) else { throw ESFailure(text: "hours must be 1–24") }
        hours = h
    } else {
        hours = 1
    }
    guard let upPid = esUpPid(paths) else {
        throw ESFailure(text: "rampctl up is not running (auto-stop runs inside it)")
    }
    let response = try await esRequest("postpone \(hours)", paths: paths, upPid: upPid)
    if response.code == 0 { esOut(response.message) } else { esErr("error: \(response.message)") }
    return response.code
}

private func esAutoStop(_ args: [String], paths: Paths) async throws -> Int32 {
    let store = ConfigStore(paths: paths)
    var settings = try await store.load().elasticsearch.autoStop
    guard args.count.isMultiple(of: 2) else { throw ESUsageError() }
    var index = 0
    while index < args.count {
        let value = args[index + 1]
        switch args[index] {
        case "--after":
            if value == "off" {
                settings.afterHours = nil
            } else {
                guard let h = Int(value) else { throw AutoStopError.invalidAfterHours(-1) }
                settings.afterHours = h
            }
        case "--at":
            settings.atTime = value == "off" ? nil : value
        default: throw ESUsageError()
        }
        index += 2
    }
    try settings.validate()
    if let t = settings.time { settings.atTime = t.description }   // "1:00" → "01:00"
    if !args.isEmpty {
        let final = settings
        try await store.update { $0.elasticsearch.autoStop = final }
    }
    esOut("auto-stop: " + esAutoStopRules(settings) + (args.isEmpty ? "" : " (applies on the next tick)"))
    return 0
}

private func esSize(_ dir: URL) -> String {
    let fm = FileManager.default
    var total: Int64 = 0
    if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
    }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
}

private func esHeap(_ raw: String, paths: Paths) async throws -> Int32 {
    let heap = try ElasticsearchService.validateHeap(raw)
    try await ConfigStore(paths: paths).update { $0.elasticsearch.heap = heap }
    esOut("elasticsearch heap: \(heap)")
    if let upPid = esUpPid(paths) {
        let response = try await esRequest("apply", paths: paths, upPid: upPid)
        if response.code == 0 { esOut("elasticsearch: \(response.message)") } else { esErr("error: \(response.message)") }
        return response.code
    }
    esOut("applies on the next start")
    return 0
}

private func esPlugin(_ args: [String], paths: Paths) async throws -> Int32 {
    guard let sub = args.first else { throw ESUsageError() }
    let service = detachedService(paths)
    let running = esLivePid(paths.pidFile(service: ServiceID.elasticsearch.name)) != nil
    switch (sub, args.count) {
    case ("list", 1):
        let names = try await service.listPlugins()
        esOut(names.isEmpty ? "(no plugins)" : names.joined(separator: "\n"))
    case ("install", 2):
        let change = try await service.installPlugin(args[1], running: running)
        esOut(change.changed ? "installed \(change.name)" : "\(change.name) already installed")
        if change.restartRequired { esOut("restart required: rampctl es restart") }
    case ("remove", 2):
        let change = try await service.removePlugin(args[1], running: running)
        esOut(change.changed ? "removed \(change.name)" : "\(change.name) is not installed")
        if change.restartRequired { esOut("restart required: rampctl es restart") }
    default: throw ESUsageError()
    }
    return 0
}
