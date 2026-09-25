import Darwin
import Foundation
import RAMPCore

// rampctl — dev CLI for the RAMP stack (no GUI). Honors RAMP_HOME / RAMP_LOGS.
//
//   rampctl install --manifest <url|path>   store manifest URL, install the default set
//   rampctl up                              prepare + start all, supervise until SIGINT/SIGTERM (then stop all);
//                                           SIGHUP = re-render configs + minimal reload + Apache graceful reload
//   rampctl status                          services from pid files (works while `up` runs elsewhere)
//   rampctl reload                          SIGHUP to the running `rampctl up`
//   rampctl paths                           print the layout
//   rampctl php …                           PHP ini/extensions/xdebug/opcache/cache clear (PHPCommands.swift)
//   rampctl vhost … / hosts …               vhost CRUD + hosts block sync (VhostCommands.swift)
//   rampctl es …                            Elasticsearch on demand (ElasticsearchCommands.swift); `up` never starts
//                                           it, SIGUSR1 = serve run/es-requests/*.req
//   rampctl open phpmyadmin|elasticvue      print the phpMyAdmin / Elasticvue URL (OpenCommand.swift)
//   rampctl update …                        check / apply / rollback service updates (UpdateCommands.swift);
//                                           with `up` running handed over via run/update-requests + SIGUSR1
//   rampctl cli …                           terminal: ~/.ramp/bin shims, PATH block, MAMP lines (CLICommands.swift)

let paths = Paths.standard()
let upPidFile = paths.runDir.appending(path: "rampctl.pid", directoryHint: .notDirectory)

func out(_ s: String) { print(s); fflush(stdout) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func usage() -> Never {
    err("""
    usage: rampctl install --manifest <url|path>
           rampctl up | status | reload | paths
    """ + "\n" + phpUsageText + "\n" + vhostUsageText + "\n" + openUsageText + "\n" + esUsageText + "\n" + uninstallUsageText + "\n" + importUsageText + "\n" + updateUsageText + "\n" + manifestUsageText + "\n" + cliUsageText)
    exit(64)
}

func describe(_ state: ServiceState) -> String {
    switch state {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .running(let pid, _): return "running (pid \(pid))"
    case .stopping: return "stopping"
    case .backingOff(let attempt, let until):
        return "restarting (attempt \(attempt), at \(until.formatted(date: .omitted, time: .standard)))"
    case .failed(let reason): return "FAILED: \(reason)"
    }
}

func manifestURL(from arg: String) -> URL {
    if let url = URL(string: arg), let scheme = url.scheme, scheme == "file" || scheme == "https" || scheme == "http" {
        return url
    }
    let path = (arg as NSString).expandingTildeInPath
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    return URL(filePath: absolute).standardizedFileURL
}

func readPid(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
    else { return nil }
    return pid
}

// MARK: Commands

func install(_ args: [String]) async -> Int32 {
    guard args.count == 2, args[0] == "--manifest" else { usage() }
    let url = manifestURL(from: args[1])
    let store = ConfigStore(paths: paths)
    do {
        try paths.ensureDirectories()
        try await store.update { $0.manifestURL = url }
        let manifest = try await ManifestLoader.load(url)
        out("manifest: \(url.absoluteString)")
        let installer = PackageInstaller(paths: paths, configStore: store)
        let (progress, task) = installer.installDefaultSetWithProgress(manifest)
        for await p in progress {
            switch p.stage {
            case .installed(let pkg): out("  \(p.component) \(p.branch): installed \(pkg.version)")
            case .failed(let msg): out("  \(p.component) \(p.branch): FAILED \(msg)")
            case .downloading where p.download == nil: out("  \(p.component) \(p.branch): downloading…")
            default: break
            }
        }
        let report = await task.value
        out("installed \(report.installed.count), failed \(report.failures.count)")
        return report.succeeded ? 0 : 1
    } catch {
        err("install failed: \(error.localizedDescription)")
        return 1
    }
}

func up() async -> Int32 {
    if let other = readPid(upPidFile) {
        err("rampctl up is already running (pid \(other))")
        return 1
    }
    // Block the signals; they are consumed through dispatch sources.
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] { signal(sig, SIG_IGN) }
    let (signals, continuation) = AsyncStream<Int32>.makeStream()
    let queue = DispatchQueue(label: "rampctl.signals")
    let sources = [SIGINT, SIGTERM, SIGHUP, SIGUSR1].map { sig -> any DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler { continuation.yield(sig) }
        src.resume()
        return src
    }

    let controller = StackController(paths: paths, mysqlTmpSocketLink: MySQLTmpSocketLink.standardPath(),
                                     cliHome: CLIIntegration.automaticHome())
    let eventTask = Task {
        for await event in controller.events {
            switch event {
            case .stateChanged(let id, let state): out("[\(id.name)] \(describe(state))")
            case .restartScheduled(let id, let attempt, let delay): out("[\(id.name)] crashed, restart #\(attempt) in \(delay)")
            case .reloaded(let id, let pid): out("[\(id.name)] reloaded (pid \(pid))")
            case .exited: break
            }
        }
    }

    do {
        try paths.ensureDirectories()
        try Data("\(getpid())\n".utf8).write(to: upPidFile, options: .atomic)
        let devManifest = ProcessInfo.processInfo.environment["RAMP_DEV_MANIFEST"].flatMap { URL(string: $0) }
        if let report = try await controller.ensureInstalled(fallbackManifestURL: devManifest) {
            for f in report.failures { err("install \(f.component) \(f.branch) failed: \(f.message)") }
        }
        try await controller.prepare()
        let report = try await controller.startAll()
        out("--- stack up (\(report.errors.isEmpty ? "all services running" : "\(report.errors.count) failed")) ---")
        for row in await controller.orderedStatus() { out("  \(row.id.name): \(describe(row.state))") }
    } catch {
        err("up failed: \(error.localizedDescription)")
        await controller.stopAll()
        try? FileManager.default.removeItem(at: upPidFile)
        return 1
    }

    // ES auto-stop (06-04): same scheduler as the app; ticks every 30 s.
    let esService = ElasticsearchService(stack: controller)
    let esAutoStop = esMakeAutoStop(service: esService, paths: paths)
    let esAutoStopTask = Task { await esAutoStop.run() }
    if let override = ElasticsearchAutoStopScheduler.overrideFromEnvironment() {
        out("elasticsearch auto-stop override: \(Int(override)) s (\(ElasticsearchAutoStopScheduler.overrideEnvironmentKey))")
    }
    let esWorker = ESRequestWorker(controller: controller, paths: paths, service: esService,
                                   autoStop: esAutoStop)   // rampctl es … requests (06-03)
    let updateWorker = UpdateRequestWorker(controller: controller, paths: paths)   // rampctl update … (07-02)
    for await sig in signals {
        if sig == SIGUSR1 {
            esWorker.wake()
            updateWorker.wake()
            continue
        }
        if sig == SIGHUP {
            do {
                let r = try await controller.applyConfigChanges()
                if !r.reloaded.contains(.apache), await controller.status()[.apache]?.isRunning == true {
                    try await controller.reloadApache()
                }
                out("reload: changed \(r.changed.count) file(s); reloaded \(r.reloaded.map(\.name)), "
                    + "restarted \(r.restarted.map(\.name))" + (r.errors.isEmpty ? "" : ", errors \(r.errors)"))
            } catch {
                err("reload failed: \(error.localizedDescription)")
            }
            continue
        }
        out("--- stopping (signal \(sig)) ---")
        break
    }
    esAutoStopTask.cancel()
    await controller.stopAll()
    await esAutoStop.sessionEnded()
    esWorker.cancel()
    updateWorker.cancel()
    eventTask.cancel()
    sources.forEach { $0.cancel() }
    try? FileManager.default.removeItem(at: upPidFile)
    out("--- stopped ---")
    return 0
}

func status() async -> Int32 {
    let config: RampConfig
    let specs: [ServiceSpec]
    do {
        config = try await ConfigStore(paths: paths).load()
        specs = try ServiceSpecFactory.specs(config: config, paths: paths)
    } catch {
        err("status: \(error.localizedDescription)")
        return 1
    }
    if let pid = readPid(upPidFile) { out("rampctl up: running (pid \(pid))") } else { out("rampctl up: not running") }
    var allRunning = true
    var mysqlRunning = false
    for spec in specs {
        if let pid = readPid(paths.pidFile(service: spec.id.name)) {
            out("  \(spec.id.name): running (pid \(pid))")
            if case .mysql = spec.id { mysqlRunning = true }
        } else {
            allRunning = false
            out("  \(spec.id.name): stopped")
        }
    }
    printTmpSocketLink(config: config, expected: mysqlRunning ? paths.mysqlSocket(major: config.mysql.branch) : nil)
    return allRunning ? 0 : 3
}

func reload() -> Int32 {
    guard let pid = readPid(upPidFile) else {
        err("rampctl up is not running")
        return 1
    }
    guard kill(pid, SIGHUP) == 0 else {
        err("cannot signal rampctl up (pid \(pid))")
        return 1
    }
    out("reload requested (pid \(pid))")
    return 0
}

func printPaths() async -> Int32 {
    out("root:    \(paths.root.path(percentEncoded: false))")
    out("logs:    \(paths.logs.path(percentEncoded: false))")
    out("config:  \(paths.configFile.path(percentEncoded: false))")
    out("run:     \(paths.runDir.path(percentEncoded: false))")
    out("docroot: \(paths.defaultDocroot.path(percentEncoded: false))")
    let config = try? await ConfigStore(paths: paths).load()
    let socket = paths.mysqlSocket(major: config?.mysql.branch ?? MySQLSettings().branch)
    out("mysql:   \(socket.path(percentEncoded: false))")
    printTmpSocketLink(config: config, expected: nil)
    return 0
}

/// `/tmp/mysql.sock` compatibility link state (status / paths).
func printTmpSocketLink(config: RampConfig?, expected: URL?) {
    guard let linkPath = MySQLTmpSocketLink.standardPath() else {
        out("tmp mysql.sock link: disabled (\(MySQLTmpSocketLink.environmentKey)=)")
        return
    }
    let link = MySQLTmpSocketLink(linkPath: linkPath, paths: paths)
    let setting = config?.mysql.tmpSocketSymlink ?? true ? "" : " [setting off]"
    out("\(linkPath.path(percentEncoded: false)): \(link.describe(expectedTarget: expected))\(setting)")
}

// MARK: Main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usage() }
let rest = Array(argv.dropFirst())
let code: Int32
switch command {
case "install": code = await install(rest)
case "up": code = await up()
case "status": code = await status()
case "reload": code = reload()
case "paths": code = await printPaths()
case "php": code = await phpCommand(rest)   // PHPCommands.swift (04-03)
case "vhost": code = await vhostCommand(rest)   // VhostCommands.swift (03-05)
case "hosts": code = await hostsCommand(rest)   // VhostCommands.swift (03-05)
case "es": code = await esCommand(rest)   // ElasticsearchCommands.swift (06-03)
case "open": code = await openCommand(rest)   // OpenCommand.swift (04-04)
case "update": code = await updateCommand(rest)   // UpdateCommands.swift (07-02)
case "uninstall": code = await uninstallCommand(rest)   // UninstallCommand.swift (07-07)
case "import": code = await importCommand(rest)   // ImportCommands.swift (07-04)
case "manifest": code = await manifestCommand(rest)   // ManifestCommands.swift (08-02)
case "cli": code = await cliCommand(rest)   // CLICommands.swift (terminal integration)
default: usage()
}
exit(code)
