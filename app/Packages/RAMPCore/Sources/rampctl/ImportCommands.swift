import Darwin
import Foundation
import RAMPCore

// rampctl import mysql … (plan 07-04) — MAMP PRO MySQL 8.0 → RAMP migration engine (MySQLMigration).
//
//   rampctl import mysql precheck [--source <datadir>] [--method datadir|logical] [--target 9.7|8.4]
//                                 [--source-socket <sock>]                      exit 0 = ok, 2 = blockers
//   rampctl import mysql run --method datadir|logical [--source <datadir>] [--target 9.7|8.4]
//                            [--root-password-stdin] [--root-auth <plugin>] [--auth user@host=<plugin>]…
//                            [--keep-84] [--source-socket <sock>] [--replace-existing]
//        stdin (with --root-password-stdin): line 1 = MAMP root password; further lines
//        "user@host<TAB>password" for --auth accounts that must be re-hashed. Passwords never go into argv.
//        <plugin> = caching_sha2_password (default) | sha256_password | mysql_native_password (target 8.4 only)
//        Exit: 0 done, 1 failed, 3 source in use (sourceInUse), 4 cancelled.
//   rampctl import mysql status | cancel | discard
//
// Test hook: RAMP_TEST_FAIL_AFTER_FILES=<n> interrupts the datadir copy after n files.

let importUsageText = """
       rampctl import mysql precheck [--source <datadir>] [--method datadir|logical] [--target 9.7|8.4] [--source-socket <sock>]
       rampctl import mysql run --method datadir|logical [--source <datadir>] [--target 9.7|8.4] [--root-password-stdin]
                                [--root-auth <plugin>] [--auth user@host=<plugin>]… [--keep-84] [--source-socket <sock>] [--replace-existing]
       rampctl import mysql status | cancel | discard
""" + "\n" + mampImportUsageText

func importCommand(_ args: [String]) async -> Int32 {
    if args.first == "mamp" { return await mampImportCommand(Array(args.dropFirst())) }   // 07-05
    if args.first == "es" { return await esImportCommand(Array(args.dropFirst())) }       // 07-05
    guard args.first == "mysql", args.count >= 2 else { usage() }
    let sub = args[1]
    let opts = Array(args.dropFirst(2))
    switch sub {
    case "precheck": return await mysqlImportPrecheck(opts)
    case "run": return await mysqlImportRun(opts)
    case "status": return mysqlImportStatus()
    case "cancel": return mysqlImportCancel()
    case "discard": return await mysqlImportDiscard()
    default: usage()
    }
}

private struct ImportArgs {
    var source = SourceUsageProbe.mampDatadir
    var method: MigrationMethod = .datadirUpgrade
    var methodGiven = false
    var target = "9.7"
    var sockets: [URL]?
    var passwordStdin = false
    var rootAuth: MySQLAuthPlugin = .cachingSHA2
    var auth: [AccountAuthRequest] = []
    var keep84 = false
    var replaceExisting = false
}

private func absoluteURL(_ path: String, directory: Bool) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let abs = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    return URL(filePath: abs, directoryHint: directory ? .isDirectory : .notDirectory).standardizedFileURL
}

private func parseImportArgs(_ args: [String]) -> ImportArgs {
    var a = ImportArgs()
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--source": a.source = absoluteURL(value(), directory: true)
        case "--method":
            switch value() {
            case "datadir": a.method = .datadirUpgrade
            case "logical": a.method = .logical
            default: usage()
            }
            a.methodGiven = true
        case "--target":
            a.target = value()
            guard a.target == "9.7" || a.target == "8.4" else { usage() }
        case "--source-socket": a.sockets = (a.sockets ?? []) + [absoluteURL(value(), directory: false)]
        case "--root-password-stdin": a.passwordStdin = true
        case "--root-auth":
            guard let p = MySQLAuthPlugin.parse(value()) else { usage() }
            a.rootAuth = p
        case "--auth":
            guard let r = AccountAuthRequest.parse(value()) else { usage() }
            a.auth.append(r)
        case "--keep-84": a.keep84 = true
        case "--replace-existing": a.replaceExisting = true
        default: usage()
        }
        i += 1
    }
    return a
}

private func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

private func mysqlImportPrecheck(_ args: [String]) async -> Int32 {
    let a = parseImportArgs(args)
    let migration = MySQLMigration(paths: paths)
    let p = await migration.precheck(source: a.source, method: a.method, targetBranch: a.target, sourceSockets: a.sockets)
    out("MySQL import precheck (\(a.method.rawValue), target \(a.target))")
    out("  source:          \(p.source.path(percentEncoded: false))")
    out("  exists/readable: \(p.sourceExists ? "yes" : "NO") / \(p.sourceReadable ? "yes" : "NO")")
    out("  source in use:   \(p.usage.inUse ? "YES" : "no")")
    for reason in p.usage.reasons { out("                   - \(reason)") }
    if let reachable = p.sourceReachable { out("  source reachable: \(reachable ? "yes" : "NO")") }
    out("  schemas:         \(p.schemas.count) (\(p.schemas.joined(separator: ", ")))")
    out("  files:           \(p.sizes.fileCount) (to copy \(p.sizes.toCopyFiles))")
    out("  total:           \(gb(p.sizes.totalBytes))")
    out("  binlogs:         \(gb(p.sizes.binlogBytes)) (excluded)")
    out("  logs:            \(gb(p.sizes.logBytes)) (excluded)")
    out("  other excluded:  \(gb(p.sizes.excludedBytes))")
    out("  to copy:         \(gb(p.sizes.toCopyBytes))")
    out("  clone possible:  \(p.clonePossible ? "yes (APFS, same volume)" : "no")")
    out("  free / required: \(p.freeBytes.map(gb) ?? "?") / \(gb(p.requiredBytes))")
    for pkg in p.packages {
        out("  mysql \(pkg.branch):       installed \(pkg.installed ?? "-"), manifest \(pkg.inManifest ?? "-")"
            + (pkg.installed == nil ? ", download \(pkg.downloadSize.map { gb($0) } ?? "?")" : ""))
    }
    out("  mysqlsh:         \(p.mysqlshPath ?? "not on PATH")")
    if let auto = p.mysqldAutoCnf { out("  mysqld-auto.cnf (not copied): \(auto.trimmingCharacters(in: .whitespacesAndNewlines))") }
    for w in p.warnings { out("  warning: \(w)") }
    for problem in p.problems { out("  BLOCKER: \(problem)") }
    out(p.ok ? "precheck: OK" : "precheck: \(p.problems.count) blocker(s)")
    return p.ok ? 0 : 2
}

private func describe(_ p: MigrationProgress) -> String? {
    switch p {
    case .phase(let phase): return "phase: \(phase.rawValue)"
    case .step(let step): return "step: \(step.rawValue)…"
    case .copy(let c):
        return "copy: \(c.filesDone)/\(c.filesTotal) files, \(gb(c.bytesDone)) / \(gb(c.bytesTotal)) (\(c.currentFile))"
    case .server(let branch, let elapsed, let line):
        return elapsed % 10 == 0 ? "mysql \(branch): \(elapsed) s — \(line ?? "")" : nil
    case .database(let name, let index, let total): return "database \(index)/\(total): \(name)"
    case .info(let text): return text
    }
}

private func mysqlImportRun(_ args: [String]) async -> Int32 {
    var a = parseImportArgs(args)
    guard a.methodGiven else { usage() }
    var rootPassword = "root"
    if a.passwordStdin {
        var lines: [String] = []
        while let line = readLine(strippingNewline: true) { lines.append(line) }
        rootPassword = lines.first ?? ""
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count == 2, let at = parts[0].lastIndex(of: "@") else { continue }
            let user = String(parts[0][..<at]), host = String(parts[0][parts[0].index(after: at)...])
            if let idx = a.auth.firstIndex(where: { $0.user == user && $0.host == host }) {
                a.auth[idx].password = parts[1]
            }
        }
    }
    let interrupt = ProcessInfo.processInfo.environment["RAMP_TEST_FAIL_AFTER_FILES"].flatMap(Int.init)
    let options = MigrationOptions(method: a.method, source: a.source, targetBranch: a.target, rootPassword: rootPassword,
                                   rootAuthPlugin: a.rootAuth, accountRequests: a.auth, keep84: a.keep84,
                                   sourceSockets: a.sockets, leaveRunning: false,
                                   replaceExistingDatabases: a.replaceExisting, interruptCopyAfterFiles: interrupt)
    let migration = MySQLMigration(paths: paths, lock: MaintenanceLock(paths: paths))   // 07-05: global lock

    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let queue = DispatchQueue(label: "rampctl.import.signals")
    let sources = [SIGINT, SIGTERM].map { sig -> any DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler {
            err("cancel requested (signal \(sig)) — stopping cleanly…")
            Task { await migration.cancel() }
        }
        src.resume()
        return src
    }
    defer { sources.forEach { $0.cancel() } }

    let (stream, continuation) = AsyncStream<MigrationProgress>.makeStream()
    let printer = Task {
        for await p in stream { if let line = describe(p) { out(line) } }
    }
    let started = Date()
    do {
        let state = try await migration.run(options, progress: continuation)
        await printer.value
        printState(state)
        out(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
        return 0
    } catch {
        await printer.value
        if let e = error as? MigrationError {
            if case .sourceInUse = e {
                err("sourceInUse: \(e.localizedDescription)")
                return 3
            }
            if case .cancelled = e {
                err(e.localizedDescription)
                return 4
            }
        }
        err("import failed: \(error.localizedDescription)")
        return 1
    }
}

private func printState(_ s: MigrationState) {
    out("state: \(s.method.rawValue) \(s.sourcePath) → \(s.targetBranch), phase \(s.phase.rawValue)")
    if let f = s.failure { out("  FAILED at \(f.step): \(f.message)") }
    if s.copiedFiles + s.skippedFiles > 0 {
        out("  copy: \(s.copiedFiles) files copied, \(s.skippedFiles) skipped (resume), \(gb(s.copiedBytes))")
    }
    for (branch, version) in s.serverVersions.sorted(by: { $0.key < $1.key }) { out("  version \(branch): \(version)") }
    for (branch, markers) in s.upgradeMarkers.sorted(by: { $0.key < $1.key }) {
        for m in markers { out("  log \(branch): \(m)") }
    }
    if let lc = s.lowerCaseTableNames { out("  lower_case_table_names: \(lc)") }
    out("  schemas (\(s.schemas.count)): \(s.schemas.joined(separator: ", "))")
    let counts = s.tableCountsFinal.isEmpty ? s.tableCounts84 : s.tableCountsFinal
    if !counts.isEmpty {
        out("  tables: " + counts.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    }
    for c in s.convertedAccounts { out("  converted: '\(c.user)'@'\(c.host)' \(c.from) → \(c.to)") }
    for a in s.keptNativeAccounts { out("  kept mysql_native_password: \(a)") }
    for a in s.unconvertedAccounts { out("  unconverted (cannot log in on 9.x): \(a) [\(a.plugin)]") }
    if !s.doneDatabases.isEmpty { out("  imported databases: \(s.doneDatabases.joined(separator: ", "))") }
    if let db = s.inProgressDatabase { out("  interrupted database: \(db)") }
    if let aside = s.movedAsidePath { out("  previous RAMP datadir moved aside: \(aside)") }
    for (step, seconds) in s.timings.sorted(by: { $0.key < $1.key }) { out(String(format: "  timing %@: %.2f s", step, seconds)) }
    for w in s.warnings { out("  warning: \(w)") }
}

private func mysqlImportStatus() -> Int32 {
    let migration = MySQLMigration(paths: paths)
    if let pid = migration.runningPID() { out("running (pid \(pid))") }
    guard let state = migration.loadState() else {
        out("no MySQL import state")
        return 0
    }
    printState(state)
    return 0
}

private func mysqlImportCancel() -> Int32 {
    let migration = MySQLMigration(paths: paths)
    guard let pid = migration.runningPID(), pid > 1 else {
        err("no MySQL import is running")
        return 1
    }
    guard kill(pid, SIGTERM) == 0 else {
        err("cannot signal pid \(pid)")
        return 1
    }
    out("cancel requested (pid \(pid))")
    return 0
}

private func mysqlImportDiscard() async -> Int32 {
    do {
        try await MySQLMigration(paths: paths).discard()
        out("staging copy + state removed")
        return 0
    } catch {
        err("discard failed: \(error.localizedDescription)")
        return 1
    }
}
