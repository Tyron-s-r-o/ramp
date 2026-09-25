import Darwin
import Foundation
import RAMPCore

// rampctl import mamp … / import es … (plan 07-05).
//
//   rampctl import mamp --dry-run                                 vhost plan (read-only on MAMP PRO's httpd.conf)
//   rampctl import mamp --apply [--only a.local,b.local]
//        one validated batch (VhostService.addMany): one save → one Apache reload → one hosts sync
//   rampctl import es precheck [--source <es home>]               exit 0 ok, 2 blockers
//   rampctl import es run [--source <es home>] [--smoke]          copy data → <root>/elasticsearch-data/<branch>
//   rampctl import es remove-launchagent --yes-remove-launchagent [--source <es home>]
//        launchctl bootout + plist to the Trash (only with the flag)
//
// Test hooks: RAMP_LAUNCH_AGENTS_DIR=<dir> (LaunchAgents dir), RAMP_LAUNCHCTL=<exe> (launchctl replacement),
// RAMP_TRASH_DIR=<dir> (move the plist there instead of the user's Trash), RAMP_HOSTS_FILE (see vhost).

let mampImportUsageText = """
       rampctl import mamp --dry-run
       rampctl import mamp --apply [--only <domain>,…]
       rampctl import es precheck|run [--source <es home>] [--smoke]
       rampctl import es remove-launchagent --yes-remove-launchagent [--source <es home>]
"""

private func mbytes(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: import mamp

func mampImportCommand(_ args: [String]) async -> Int32 {
    var dryRun = false, apply = false
    var only: Set<String>?
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--dry-run": dryRun = true
        case "--apply": apply = true
        case "--only": only = Set(value().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        default: usage()
        }
        i += 1
    }
    guard dryRun != apply else { usage() }

    let store = ConfigStore(paths: paths)
    let service = VhostService(store: store, applier: DetachedVhostApplier(paths: paths, store: store),
                               hosts: hostsSyncer(paths: paths))
    let coordinator = MAMPImportCoordinator(paths: paths, store: store, vhostService: service,
                                            lock: MaintenanceLock(paths: paths))
    guard coordinator.mampLocation != nil else {
        err("MAMP PRO config not found: \(MAMPLocator.locate().httpConf.path(percentEncoded: false))")
        return 3
    }
    let plan: ImportPlan
    do {
        plan = try await coordinator.previewVhosts()   // installed PHP branches
    } catch {
        err("import mamp: \(error.localizedDescription)")
        return 2
    }
    printPlan(plan)
    guard apply else { return 0 }

    var vhosts = plan.vhostsToAdd
    if let only {
        let unknown = only.subtracting(plan.candidates.map(\.vhost.domain))
        if !unknown.isEmpty { err("--only: not a candidate: \(unknown.sorted().joined(separator: ", "))"); return 64 }
        let excluded = plan.candidates.filter { only.contains($0.vhost.domain) && !$0.include }.map(\.vhost.domain)
        if !excluded.isEmpty { err("--only: excluded by validation errors: \(excluded.joined(separator: ", "))"); return 2 }
        vhosts = vhosts.filter { only.contains($0.domain) }
    }
    guard !vhosts.isEmpty else {
        out("nothing to import")
        return 0
    }
    do {
        let result = try await coordinator.applyVhosts(vhosts)
        for w in result.warnings { out("warning: \(w.message)") }
        out("imported \(vhosts.count) vhost(s)")
        switch result.hosts {
        case .notManaged: out("hosts: not managed")
        case .synced(.unchanged): out("hosts: already in sync")
        case .synced(.updated(let via)): out("hosts: updated (\(via.rawValue))")
        case .pending(let reason): out("hosts: PENDING — \(reason) (retry: rampctl hosts sync)")
        }
        return 0
    } catch {
        err("import failed (nothing saved): \(error.localizedDescription)")
        return 2
    }
}

private func printPlan(_ plan: ImportPlan) {
    let s = plan.summary
    out("MAMP PRO vhost import plan: \(s.candidates) candidate(s), \(s.included) included, \(s.excluded) excluded, "
        + "\(s.sslOnly) HTTPS-only, \(s.skipped) skipped, \(s.warnings) warning(s), \(s.errors) error(s)")
    let rows = plan.candidates.map { c -> [String] in
        let aliases = c.vhost.aliases.count > 2
            ? c.vhost.aliases.prefix(2).joined(separator: ",") + ",…(+\(c.vhost.aliases.count - 2))"
            : c.vhost.aliases.joined(separator: ",")
        return [c.include ? "+" : "-", c.vhost.domain, aliases,
         c.vhost.phpBranch ?? "default", c.source == .sslOnly ? "https-only" : "", c.vhost.docroot]
    }
    let widths = [1, 34, 30, 7, 10].enumerated().map { idx, minimum in
        max(minimum, rows.map { $0[idx].count }.max() ?? 0)
    }
    out("  " + pad("", widths[0]) + " " + pad("domain", widths[1]) + " " + pad("aliases", widths[2]) + " "
        + pad("php", widths[3]) + " " + pad("source", widths[4]) + " docroot")
    for (row, c) in zip(rows, plan.candidates) {
        out("  " + (0..<5).map { pad(row[$0], widths[$0]) }.joined(separator: " ") + " " + row[5])
        for issue in c.issues {
            out("      \(issue.severity == .error ? "ERROR" : "warn "): \(issue.message)")
        }
    }
    for issue in plan.issues { out("  config: \(issue.severity.rawValue): \(issue.message)") }
    if !plan.skipped.isEmpty {
        out("  skipped: " + plan.skipped.map { "\($0.serverName) (\($0.reason.rawValue))" }.joined(separator: ", "))
    }
}

// MARK: import es

private func esSource(_ args: inout [String]) -> ElasticsearchSource? {
    if let idx = args.firstIndex(of: "--source") {
        guard idx + 1 < args.count else { usage() }
        let raw = (args[idx + 1] as NSString).expandingTildeInPath
        args.removeSubrange(idx...(idx + 1))
        let abs = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
        let url = URL(filePath: abs, directoryHint: .isDirectory).standardizedFileURL
        guard let source = ElasticsearchDataMigrator.source(at: url) else {
            err("not an Elasticsearch home (needs data/ and bin/elasticsearch): \(url.path(percentEncoded: false))")
            exit(3)
        }
        return source
    }
    return ElasticsearchDataMigrator.detect().first
}

private func testRemover() -> LegacyLaunchAgentRemover {
    let env = ProcessInfo.processInfo.environment
    let dir = env["RAMP_LAUNCH_AGENTS_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    var trash: LegacyLaunchAgentRemover.TrashAction?
    if let trashDir = env["RAMP_TRASH_DIR"], !trashDir.isEmpty {
        trash = { url in
            let dest = URL(filePath: trashDir, directoryHint: .isDirectory).appending(path: url.lastPathComponent)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }
    return LegacyLaunchAgentRemover(launchAgentsDir: dir, runner: SystemProcessRunner(tempDir: paths.tmp),
                                    launchctl: env["RAMP_LAUNCHCTL"] ?? "/bin/launchctl", trash: trash)
}

func esImportCommand(_ args: [String]) async -> Int32 {
    guard let sub = args.first else { usage() }
    var rest = Array(args.dropFirst())
    let explicitSource = rest.contains("--source")
    guard let source = esSource(&rest) else {
        err("no Elasticsearch installation found under ~/Lib/elasticsearch-* (use --source <es home>)")
        return 3
    }
    let config = (try? await ConfigStore(paths: paths).load()) ?? RampConfig()
    let migrator = ElasticsearchDataMigrator(paths: paths, targetBranch: config.elasticsearch.branch)
    switch sub {
    case "precheck":
        guard rest.isEmpty else { usage() }
        let p = migrator.precheck(source: source)
        printESPrecheck(p, remover: testRemover())
        return p.ok ? 0 : 2
    case "run":
        let smoke = rest.contains("--smoke")
        rest.removeAll { $0 == "--smoke" }
        guard rest.isEmpty else { usage() }
        return await esRun(source: source, migrator: migrator, config: config, smoke: smoke)
    case "remove-launchagent":
        guard rest == ["--yes-remove-launchagent"] else {
            err("refusing: pass --yes-remove-launchagent to boot out the LaunchAgent and move its plist to the Trash")
            return 64
        }
        let remover = testRemover()
        let agents = remover.find(referencing: source.root)
        guard !agents.isEmpty else {
            out("no LaunchAgent referencing \(source.root.path(percentEncoded: false))" + (explicitSource ? "" : " (detected)"))
            return 0
        }
        var code: Int32 = 0
        for agent in agents {
            do {
                let trashed = try await remover.remove(agent, referencing: source.root, confirmed: true)
                out("removed \(agent.label): booted out, plist → \((trashed ?? agent.plistURL).path(percentEncoded: false))")
            } catch {
                err("\(agent.label): \(error.localizedDescription)")
                code = 1
            }
        }
        return code
    default:
        usage()
    }
}

private func printESPrecheck(_ p: ElasticsearchMigrationPrecheck, remover: LegacyLaunchAgentRemover) {
    out("Elasticsearch data import precheck")
    out("  source:          \(p.source.root.path(percentEncoded: false)) (version \(p.source.version ?? "?"))")
    out("  target:          \(p.target.path(percentEncoded: false)) (RAMP branch \(p.targetBranch))")
    out("  version ok:      \(p.versionCompatible ? "yes" : "NO")")
    out("  source running:  \(p.sourceRunning.isEmpty ? "no" : "YES")")
    for r in p.sourceRunning { out("                   - \(r)") }
    out("  RAMP ES running: \(p.rampRunning ? "YES" : "no")")
    out("  data:            \(p.files) files, \(mbytes(p.bytes)) (excluded \(p.excludedFiles): node.lock, .DS_Store)")
    out("  clone possible:  \(p.clonePossible ? "yes (APFS, same volume)" : "no")")
    out("  free / required: \(p.freeBytes.map(mbytes) ?? "?") / \(mbytes(p.requiredBytes))")
    out("  target has data: \(p.targetHasData ? "yes (moved aside)" : "no")")
    for agent in remover.find(referencing: p.source.root) {
        out("  LaunchAgent:     \(agent.label) → \(agent.scriptPath(in: p.source.root) ?? "?") "
            + "(remove: rampctl import es remove-launchagent --yes-remove-launchagent)")
    }
    for w in p.warnings { out("  warning: \(w)") }
    for problem in p.problems { out("  BLOCKER: \(problem)") }
    out(p.ok ? "precheck: OK" : "precheck: \(p.problems.count) blocker(s)")
}

private func esRun(source: ElasticsearchSource, migrator: ElasticsearchDataMigrator, config: RampConfig,
                   smoke: Bool) async -> Int32 {
    let lock = MaintenanceLock(paths: paths)
    let token: MaintenanceToken
    do { token = try await lock.acquire(.mampImport) } catch {
        err(error.localizedDescription)
        return 1
    }
    let cancel = CancelFlag()
    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let queue = DispatchQueue(label: "rampctl.import.es.signals")
    let sources = [SIGINT, SIGTERM].map { sig -> any DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler {
            err("cancel requested — stopping after the current file…")
            cancel.cancel()
        }
        src.resume()
        return src
    }
    defer { sources.forEach { $0.cancel() } }

    var smokeTest: (@Sendable () async throws -> [String: Int])?
    if smoke {
        if config.installed["elasticsearch"]?[config.elasticsearch.branch] == nil {
            out("smoke skipped: RAMP Elasticsearch not installed")
        } else if readPid(upPidFile) != nil {
            out("smoke skipped: rampctl up is running (start ES with `rampctl es start` and check _cat/indices)")
        } else {
            let port = config.elasticsearch.httpPort
            smokeTest = { try await esSmoke(port: port) }
        }
    }
    let started = Date()
    do {
        let r = try await migrator.run(source: source, cancel: cancel, progress: { p in
            out("copy: \(p.filesDone)/\(p.filesTotal) files, \(mbytes(p.bytesDone)) / \(mbytes(p.bytesTotal))")
        }, smoke: smokeTest)
        await lock.release(token)
        out("copied \(r.filesCopied) file(s) (\(r.filesSkipped) resumed, \(r.cloned) cloned), \(mbytes(r.bytes))")
        out("target: \(r.target.path(percentEncoded: false))")
        if let aside = r.movedAside { out("previous data moved aside: \(aside.path(percentEncoded: false))") }
        if let indices = r.smokeIndices {
            out("smoke: \(indices.count) index(es): "
                + indices.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        for w in r.warnings { out("warning: \(w)") }
        out(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
        return 0
    } catch {
        await lock.release(token)
        if case ElasticsearchMigrationError.cancelled = error { err(error.localizedDescription); return 4 }
        if case ElasticsearchMigrationError.precheckFailed(let problems) = error {
            for p in problems { err("BLOCKER: \(p)") }
            return 2
        }
        err("es import failed: \(error.localizedDescription)")
        return 1
    }
}

/// Starts RAMP ES in this process (no `up` running), waits for `_cat/indices`, stops it again.
private func esSmoke(port: Int) async throws -> [String: Int] {
    let stack = StackController(paths: paths, supervisor: ServiceSupervisor(paths: paths, cleanupOrphans: false))
    let service = ElasticsearchService(stack: stack)
    _ = try await service.start()
    let deadline = Date().addingTimeInterval(120)
    var lastError: (any Error)?
    while Date() < deadline {
        do {
            let indices = try await ElasticsearchDataMigrator.catIndices(port: port)
            await service.stop()
            return indices
        } catch {
            lastError = error
            try? await Task.sleep(for: .seconds(2))
        }
    }
    await service.stop()
    throw lastError ?? ElasticsearchMigrationError.activateFailed("Elasticsearch did not answer in 120 s")
}
