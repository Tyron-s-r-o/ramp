import Foundation
import RAMPCore

// rampctl uninstall --dry-run [--dump <dir>] [--keep-hosts]
// rampctl uninstall --yes     [--dump <dir>] [--keep-hosts]
//
// Never trashes an app bundle; helper daemon / login item / preferences domain are app-only (skipped).
// `RAMP_UNINSTALL_FAKE_HOME=<dir>` judges and deletes against a fake home (tests / smoke runs).
// `RAMP_HOSTS_FILE=<file>` redirects the hosts block removal to a user-owned file.

let uninstallUsageText = "       rampctl uninstall --dry-run|--yes [--dump <dir>] [--keep-hosts]"

func uninstallCommand(_ args: [String]) async -> Int32 {
    var dryRun = false, yes = false, keepHosts = false
    var dumpDir: URL?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--dry-run": dryRun = true
        case "--yes": yes = true
        case "--keep-hosts": keepHosts = true
        case "--dump":
            guard i + 1 < args.count else { usage() }
            i += 1
            let path = (args[i] as NSString).expandingTildeInPath
            dumpDir = URL(filePath: path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path,
                          directoryHint: .isDirectory)
        default: usage()
        }
        i += 1
    }
    guard dryRun != yes else { usage() }

    let config = (try? await ConfigStore(paths: paths).load()) ?? RampConfig()
    let context = UninstallContext.live(paths: paths, config: config, appBundle: nil, allowFakeHome: true)
    let options = UninstallOptions(
        dumpDatabases: dumpDir != nil,
        dumpDirectory: dumpDir ?? context.home.appending(path: "Desktop", directoryHint: .isDirectory),
        removeHostsBlock: !keepHosts, moveAppToTrash: false, unregisterHelper: false, unregisterLoginItem: false)
    let planner = UninstallPlanner(context: context)
    let plan = planner.plan(options: options)
    out(plan.render())
    if dryRun { return plan.isExecutable ? 0 : 2 }
    guard plan.isExecutable else { return 2 }

    let hosts: HostsSyncCoordinator
    if let file = ProcessInfo.processInfo.environment["RAMP_HOSTS_FILE"], !file.isEmpty {
        let url = URL(filePath: (file as NSString).expandingTildeInPath)
        hosts = HostsSyncCoordinator(helper: nil, fallback: DirectHostsSync(path: url),
                                     reader: { try DirectHostsSync(path: url).read() })
    } else {
        hosts = HostsSyncCoordinator(helper: nil, fallback: AdminPromptHostsSync(paths: paths))
    }
    let actions = LiveUninstallActions(paths: paths, config: config, stack: StackController(paths: paths),
                                       hosts: hosts, systemIntegration: false)
    let steps = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, $0.description) })
    let report = await Uninstaller(actions: actions, pathGuard: planner.pathGuard).execute(plan) { p in
        switch p.status {
        case .running: break
        case .done: out("  ok    \(steps[p.stepID] ?? "")")
        case .skipped(let why): out("  skip  \(steps[p.stepID] ?? "") (\(why))")
        case .failed(let why): out("  FAIL  \(steps[p.stepID] ?? ""): \(why)")
        }
    }
    if let aborted = report.aborted {
        err("uninstall aborted: \(aborted)")
        return 1
    }
    if let dump = report.dumpFile { out("database backup: \(dump.path(percentEncoded: false))") }
    for w in report.warnings { err("warning: \(w)") }
    for m in report.manualSteps { out("manual cleanup: \(m)") }
    return report.warnings.isEmpty ? 0 : 3
}
