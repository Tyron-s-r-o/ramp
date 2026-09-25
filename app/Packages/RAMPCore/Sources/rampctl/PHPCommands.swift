import Darwin
import Foundation
import RAMPCore

// rampctl php … (plan 04-03). Runs next to a live `rampctl up` / app: config changes are validated,
// saved, rendered here, `php-fpm -t`-checked and applied by SIGUSR2 to that branch's FPM master only
// (`DetachedPHPStack`). Errors print the message and exit 2.
//
//   rampctl php list
//   rampctl php available                         manifest branches: version, size, support phase, installed
//   rampctl php install <branch> [--manifest <url|path>]
//   rampctl php uninstall <branch>                refused for the default / phpMyAdmin's / a vhost's branch
//   rampctl php enable|disable <branch>
//   rampctl php ini get <branch> [key]
//   rampctl php ini set [--global | <branch>] <key> <value>
//   rampctl php ini unset [--global | <branch>] <key>
//   rampctl php ext <branch> <name> on|off
//   rampctl php xdebug <branch> off|debug|profile
//   rampctl php opcache <branch> [--enable on|off] [--jit on|off] [--profile dev|perf]
//   rampctl php clear-opcache <branch>
//   rampctl php clear-apcu <branch>

let phpUsageText = """
       rampctl php list
       rampctl php available
       rampctl php install <branch> [--manifest <url|path>]
       rampctl php uninstall <branch>
       rampctl php enable|disable <branch>
       rampctl php ini get <branch> [key]
       rampctl php ini set [--global | <branch>] <key> <value>
       rampctl php ini unset [--global | <branch>] <key>
       rampctl php ext <branch> <name> on|off
       rampctl php xdebug <branch> off|debug|profile
       rampctl php opcache <branch> [--enable on|off] [--jit on|off] [--profile dev|perf]
       rampctl php clear-opcache|clear-apcu <branch>
"""

private struct PHPUsageError: Error {}

private func phpOut(_ s: String) { print(s); fflush(stdout) }
private func phpErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private func message(_ error: any Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}

private func onOff(_ s: String) throws -> Bool {
    switch s {
    case "on", "1", "true", "yes": return true
    case "off", "0", "false", "no": return false
    default: throw PHPUsageError()
    }
}

private func branchKey(_ b: String) -> [Int] { b.split(separator: ".").map { Int($0) ?? 0 } }

private func printReport(_ r: ConfigApplyReport) {
    let reloaded = r.reloaded.map(\.name)
    phpOut(r.changed.isEmpty ? "no change" : "changed \(r.changed.count) file(s); reloaded \(reloaded.isEmpty ? "none (FPM not running)" : reloaded.joined(separator: ", "))")
    for (id, e) in r.errors.sorted(by: { $0.key.name < $1.key.name }) where r.preflightFailed[id] == nil {
        phpErr("warning: \(id.name): \(e)")
    }
}

/// Entry point for `rampctl php …`.
func phpCommand(_ args: [String]) async -> Int32 {
    let paths = Paths.standard()
    let store = ConfigStore(paths: paths)
    let stack = DetachedPHPStack(paths: paths, store: store)
    let manager = PHPManager(store: store, stack: stack, paths: paths)
    do {
        guard let sub = args.first else { throw PHPUsageError() }
        let a = Array(args.dropFirst())
        switch sub {
        case "list":
            let config = try await store.load()
            let branches = (config.installed["php"] ?? [:]).keys.sorted { branchKey($0).lexicographicallyPrecedes(branchKey($1)) }
            for b in branches {
                let s = config.php.branches[b] ?? PHPBranchSettings()
                let running = stack.masterPID(branch: b).map { "running (pid \($0))" } ?? "stopped"
                let available = try await manager.availableExtensions(branch: b).sorted()
                let enabled = s.enabled ? (try await manager.enabledExtensions(branch: b)) : []
                phpOut("\(b)  \(config.installed["php"]![b]!.version)  \(s.enabled ? running : "disabled")  xdebug=\(s.xdebug.rawValue)"
                       + "  opcache=\(s.opcache.enabled ? s.opcache.profile.rawValue : "off")\(s.opcache.jit ? "+jit" : "")")
                phpOut("    enabled:   \(enabled.isEmpty ? "-" : enabled.joined(separator: " "))")
                phpOut("    available: \(available.isEmpty ? "-" : available.joined(separator: " "))")
            }
        case "available":
            guard a.isEmpty else { throw PHPUsageError() }
            for o in try await manager.offers() {
                let size = o.size.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "? MB"
                let support: String
                switch o.support {
                case .active?: support = "active support" + (o.eolDate.map { " (security until \($0))" } ?? "")
                case .security?: support = "security fixes only" + (o.eolDate.map { " (until \($0))" } ?? "")
                case .eol?: support = "END OF LIFE" + (o.eolDate.map { " (since \($0))" } ?? "")
                case nil: support = "support unknown"
                }
                var state = o.installedVersion.map { "installed \($0)" } ?? "not installed"
                if o.uninstallBlocker != nil { state += ", in use" }
                phpOut("\(o.branch)  \(o.version)  \(size)  \(support)  [\(state)]")
            }
        case "install":
            guard a.count == 1 || (a.count == 3 && a[1] == "--manifest") else { throw PHPUsageError() }
            let branch = a[0]
            let manifest: Manifest? = a.count == 3 ? try await ManifestLoader.load(phpManifestURL(a[2])) : nil
            try paths.ensureDirectories()
            let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
            let printer = Task {
                for await p in progress {
                    switch p.stage {
                    case .downloading where p.download == nil: phpOut("php \(p.branch): downloading…")
                    case .verifying: phpOut("php \(p.branch): verifying checksum…")
                    case .extracting: phpOut("php \(p.branch): extracting…")
                    case .activating: phpOut("php \(p.branch): activating…")
                    case .installed(let pkg): phpOut("php \(p.branch): installed \(pkg.version)")
                    case .failed, .downloading: break
                    }
                }
            }
            let record = try await manager.installBranch(branch, manifest: manifest, progress: continuation)
            await printer.value
            phpOut("PHP \(branch) \(record.version) installed and enabled")
            await phpAfterBranchSetChange(paths: paths, store: store, stack: stack, branch: branch, start: true)
        case "uninstall":
            guard a.count == 1 else { throw PHPUsageError() }
            try await manager.uninstallBranch(a[0])
            phpOut("PHP \(a[0]) uninstalled")
            await phpAfterBranchSetChange(paths: paths, store: store, stack: stack, branch: a[0], start: false)
        case "enable", "disable":
            guard a.count == 1 else { throw PHPUsageError() }
            let enable = sub == "enable"
            let wasEnabled = (try await store.load()).php.branches[a[0]]?.enabled ?? true
            try await manager.setBranchEnabled(branch: a[0], enabled: enable)
            guard wasEnabled != enable else {
                phpOut("PHP \(a[0]) already \(sub)d")
                return 0
            }
            phpOut("PHP \(a[0]) \(sub)d")
            if CLIIntegration.automaticSyncAllowed() {   // terminal shims follow the enabled set
                _ = try? CLIIntegration(paths: paths).syncShims(config: try await store.load())
            }
            // Starting / stopping the FPM belongs to the process that supervises the stack.
            if let pid = readPid(upPidFile), kill(pid, SIGHUP) == 0 {
                phpOut("rampctl up (pid \(pid)) asked to \(enable ? "start" : "stop") php\(a[0])-fpm")
            } else if !enable, let pid = stack.masterPID(branch: a[0]) {
                phpOut("php\(a[0])-fpm (pid \(pid)) keeps running until the stack restarts (in the RAMP app use its toggle)")
            }
        case "ini":
            guard let op = a.first else { throw PHPUsageError() }
            let r = Array(a.dropFirst())
            switch op {
            case "get":
                guard r.count == 1 || r.count == 2 else { throw PHPUsageError() }
                let list = try await manager.effectiveIni(branch: r[0])
                let shown = r.count == 2 ? list.filter { $0.key == r[1] } : list
                if r.count == 2 && shown.isEmpty { phpErr("\(r[1]): not set by RAMP (PHP built-in default)"); return 1 }
                for d in shown { phpOut("\(d.key) = \(d.value)  (\(d.source.rawValue))") }
            case "set", "unset":
                let need = op == "set" ? 3 : 2
                guard r.count == need else { throw PHPUsageError() }
                let scope: PHPIniScope = r[0] == "--global" ? .global : .branch(r[0])
                printReport(try await manager.setIniOverride(scope: scope, key: r[1], value: op == "set" ? r[2] : nil))
            default: throw PHPUsageError()
            }
        case "ext":
            guard a.count == 3 else { throw PHPUsageError() }
            printReport(try await manager.setExtension(branch: a[0], name: a[1], enabled: try onOff(a[2])))
        case "xdebug":
            guard a.count == 2, let mode = XdebugMode(rawValue: a[1]) else { throw PHPUsageError() }
            printReport(try await manager.setXdebug(branch: a[0], mode: mode))
        case "opcache":
            guard !a.isEmpty, a.count % 2 == 1 else { throw PHPUsageError() }
            let branch = a[0]
            var options = (try await store.load()).php.branches[branch]?.opcache ?? OPcacheOptions()
            var i = 1
            while i < a.count {
                let v = a[i + 1]
                switch a[i] {
                case "--enable": options.enabled = try onOff(v)
                case "--jit": options.jit = try onOff(v)
                case "--profile":
                    switch v {
                    case "dev", "development": options.profile = .development
                    case "perf", "performance": options.profile = .performance
                    default: throw PHPUsageError()
                    }
                default: throw PHPUsageError()
                }
                i += 2
            }
            printReport(try await manager.setOPcache(branch: branch, options))
        case "clear-opcache", "clear-apcu":
            guard a.count == 1 else { throw PHPUsageError() }
            if sub == "clear-opcache" { try await manager.clearOPcache(branch: a[0]) } else { try await manager.clearAPCu(branch: a[0]) }
            phpOut("php\(a[0])-fpm reloaded (\(sub == "clear-opcache" ? "OPcache" : "APCu") cleared)")
        default:
            throw PHPUsageError()
        }
        return 0
    } catch is PHPUsageError {
        phpErr("usage:\n" + phpUsageText)
        return 64
    } catch {
        phpErr("error: \(message(error))")
        return 2
    }
}

/// `--manifest` value: file:// / https:// URL or a (relative) path.
private func phpManifestURL(_ raw: String) -> URL {
    if let u = URL(string: raw), let scheme = u.scheme, scheme == "file" || scheme == "https" { return u }
    let path = (raw as NSString).expandingTildeInPath
    return URL(filePath: path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path)
        .standardizedFileURL
}

/// After install / uninstall: terminal shims follow the branch set; a running `rampctl up` re-applies (starts
/// the new FPM). Without it the new FPM starts with the stack (the RAMP app applies on its next change / launch).
private func phpAfterBranchSetChange(paths: Paths, store: ConfigStore, stack: DetachedPHPStack, branch: String,
                                     start: Bool) async {
    if CLIIntegration.automaticSyncAllowed(), let config = try? await store.load() {
        _ = try? CLIIntegration(paths: paths).syncShims(config: config)
    }
    if let pid = readPid(upPidFile), kill(pid, SIGHUP) == 0 {
        phpOut("rampctl up (pid \(pid)) asked to apply the change\(start ? " (starts php\(branch)-fpm)" : "")")
    } else if start {
        phpOut("php\(branch)-fpm starts with the stack (rampctl up / RAMP app)")
    }
}
