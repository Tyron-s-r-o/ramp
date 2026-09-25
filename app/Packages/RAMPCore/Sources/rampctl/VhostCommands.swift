import Darwin
import Foundation
import RAMPCore

// rampctl vhost … / hosts … (plan 03-05). Runs next to a live `rampctl up` / app: a change is validated,
// saved, rendered here, `httpd -t`-checked (rolled back when rejected) and applied by SIGUSR1 (graceful)
// to the running httpd master only — FPM untouched. Hosts sync uses the password prompt (rampctl has no
// team signature, so the privileged helper is not reachable). `RAMP_HOSTS_FILE=<file>` redirects hosts
// sync to a user-owned file (tests) — then no prompt at all.
//
//   rampctl vhost list
//   rampctl vhost add <domain> <docroot> [--php <branch>] [--alias <name>]… [--group <name>]
//   rampctl vhost group <domain> <name|--none>
//   rampctl vhost rm <domain>
//   rampctl vhost enable|disable <domain>
//   rampctl hosts sync
//   rampctl hosts status

let vhostUsageText = """
       rampctl vhost list
       rampctl vhost add <domain> <docroot> [--php <branch>] [--alias <name>]… [--group <name>]
       rampctl vhost group <domain> <name|--none>
       rampctl vhost rm|enable|disable <domain>
       rampctl hosts sync | status
"""

private struct VhostUsageError: Error {}

private func vOut(_ s: String) { print(s); fflush(stdout) }
private func vErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private func vMessage(_ error: any Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}

/// Applies vhost changes from a process that does not own the stack: never creates a supervisor that
/// could clean up the live one's processes.
struct DetachedVhostApplier: VhostConfigApplying {
    let paths: Paths
    let controller: StackController

    init(paths: Paths, store: ConfigStore) {
        self.paths = paths
        controller = StackController(paths: paths, configStore: store,
                                     supervisor: ServiceSupervisor(paths: paths, cleanupOrphans: false))
    }

    func applyVhostConfig() async throws {
        let result = try await controller.writeConfigsTestingApache()
        if let failure = result.apacheTestFailure { throw VhostServiceError.apacheRejected(failure) }
        guard !result.changed.isEmpty, let pid = apachePID() else { return }
        if kill(pid, SIGUSR1) == 0 { vOut("apache: graceful reload (pid \(pid))") }
    }

    func apachePID() -> pid_t? {
        let url = paths.pidFile(service: ServiceID.apache.name)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
        else { return nil }
        return pid
    }
}

func hostsSyncer(paths: Paths) -> HostsSyncCoordinator {
    if let file = ProcessInfo.processInfo.environment["RAMP_HOSTS_FILE"], !file.isEmpty {
        let url = URL(filePath: (file as NSString).expandingTildeInPath)
        return HostsSyncCoordinator(helper: nil, fallback: DirectHostsSync(path: url),
                                    reader: { try DirectHostsSync(path: url).read() })
    }
    return HostsSyncCoordinator(helper: nil, fallback: AdminPromptHostsSync(paths: paths))
}

private func describe(_ state: HostsSyncState) -> String {
    switch state {
    case .notManaged: return "hosts: not managed (hosts.manageHostsFile = false)"
    case .synced(.unchanged): return "hosts: already in sync"
    case .synced(.updated(let via)): return "hosts: updated (\(via.rawValue))"
    case .pending(let reason): return "hosts: PENDING — \(reason) (retry: rampctl hosts sync)"
    }
}

private func absolutePath(_ arg: String) -> String {
    let path = (arg as NSString).expandingTildeInPath
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    return URL(filePath: absolute).standardizedFileURL.path(percentEncoded: false)
}

/// `vhost list` table: state, group, domain (+ aliases), PHP, docroot. Sorted by group (ungrouped last), then domain.
func vhostListLines(_ vhosts: [Vhost]) -> [String] {
    let sorted = vhosts.sorted { a, b in
        switch (a.group, b.group) {
        case let (x?, y?) where x.localizedStandardCompare(y) != .orderedSame:
            return x.localizedStandardCompare(y) == .orderedAscending
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.domain.localizedStandardCompare(b.domain) == .orderedAscending
        }
    }
    let groupWidth = min(Vhost.maxGroupLength, max(5, sorted.map { ($0.group ?? "-").count }.max() ?? 0))
    func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
    guard !sorted.isEmpty else { return [] }
    var lines = ["  " + pad("GROUP", groupWidth) + "  DOMAIN / PHP / DOCROOT"]
    for v in sorted {
        let aliases = v.aliases.isEmpty ? "" : " (+ \(v.aliases.joined(separator: ", ")))"
        lines.append("\(v.enabled ? "●" : "○") \(pad(v.group ?? "-", groupWidth))  \(v.domain)\(aliases)  php \(v.phpBranch ?? "default")  \(v.docroot)")
    }
    return lines
}

func vhostCommand(_ args: [String]) async -> Int32 {
    let paths = Paths.standard()
    let store = ConfigStore(paths: paths)
    let service = VhostService(store: store, applier: DetachedVhostApplier(paths: paths, store: store),
                               hosts: hostsSyncer(paths: paths))
    do {
        guard let sub = args.first else { throw VhostUsageError() }
        var a = Array(args.dropFirst())
        let result: VhostChangeResult
        switch sub {
        case "list":
            guard a.isEmpty else { throw VhostUsageError() }
            for line in vhostListLines(try await service.list()) { vOut(line) }
            return 0
        case "add":
            guard a.count >= 2 else { throw VhostUsageError() }
            let domain = a.removeFirst()
            let docroot = absolutePath(a.removeFirst())
            var php: String?
            var aliases: [String] = []
            var group: String?
            while !a.isEmpty {
                let flag = a.removeFirst()
                guard !a.isEmpty else { throw VhostUsageError() }
                switch flag {
                case "--php": php = a.removeFirst()
                case "--alias": aliases.append(a.removeFirst())
                case "--group": group = a.removeFirst()
                default: throw VhostUsageError()
                }
            }
            result = try await service.add(Vhost(domain: domain, aliases: aliases, docroot: docroot, phpBranch: php,
                                                 group: group))
        case "group":
            guard a.count == 2 else { throw VhostUsageError() }
            let vhost = try await service.find(a[0])
            let group: String? = a[1] == "--none" ? nil : a[1]
            try await service.setGroup(ids: [vhost.id], group)
            vOut("ok: group \(vhost.domain) → \(Vhost.normalizeGroup(group) ?? "(none)")")
            return 0
        case "rm", "remove":
            guard a.count == 1 else { throw VhostUsageError() }
            result = try await service.remove(id: try await service.find(a[0]).id)
        case "enable", "disable":
            guard a.count == 1 else { throw VhostUsageError() }
            result = try await service.setEnabled(id: try await service.find(a[0]).id, sub == "enable")
        default:
            throw VhostUsageError()
        }
        for w in result.warnings { vOut("warning: \(w.message)") }
        vOut("ok: \(sub) \(args.dropFirst().first ?? "")")
        vOut(describe(result.hosts))
        return 0
    } catch is VhostUsageError {
        vErr("usage:\n" + vhostUsageText)
        return 64
    } catch {
        vErr("vhost \(args.first ?? ""): \(vMessage(error))")
        return 2
    }
}

func hostsCommand(_ args: [String]) async -> Int32 {
    let paths = Paths.standard()
    let store = ConfigStore(paths: paths)
    let syncer = hostsSyncer(paths: paths)
    switch args.first {
    case "sync" where args.count == 1:
        let service = VhostService(store: store, applier: DetachedVhostApplier(paths: paths, store: store), hosts: syncer)
        let state = await service.syncHosts()
        vOut(describe(state))
        if case .pending = state { return 1 }
        return 0
    case "status" where args.count == 1:
        let helper = await HelperHostsSync().status
        vOut("helper: \(helper.rawValue)\(HelperHostsSync.ownTeamID() == nil ? " (rampctl: no team signature → password prompt)" : "")")
        do {
            let config = try await store.load()
            let names = VhostCatalog.enabledHostnames(in: config)
            vOut("managed: \(config.hosts.manageHostsFile ? "yes" : "no")")
            let inSync = try syncer.isInSync(names: config.hosts.manageHostsFile ? names : [])
            vOut("in sync: \(inSync ? "yes" : "no") (\(names.count) name(s))")
            return inSync ? 0 : 3
        } catch {
            vErr("hosts status: \(vMessage(error))")
            return 2
        }
    default:
        vErr("usage:\n" + vhostUsageText)
        return 64
    }
}
