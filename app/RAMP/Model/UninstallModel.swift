import AppKit
import Foundation
import Observation
import RAMPCore

/// Uninstall flow (07-07): dry-run plan → typed confirmation → execution with per-step progress → report.
/// DEBUG builds honor `RAMP_UNINSTALL_FAKE_HOME` (guard + deletions against a fake home, no helper / login item /
/// prefs changes) and never trash an app bundle that runs from DerivedData.
@MainActor @Observable
final class UninstallModel {
    enum Phase: Equatable {
        case idle
        case planning
        case ready
        case running
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var plan: UninstallPlan?
    private(set) var statuses: [Int: UninstallStepStatus] = [:]
    private(set) var report: UninstallReport?
    private(set) var mysqlAvailable = false

    var dumpDatabases = true { didSet { if oldValue != dumpDatabases { Task { await preparePlan() } } } }
    var removeHostsBlock = true { didSet { if oldValue != removeHostsBlock { Task { await preparePlan() } } } }
    var confirmation = ""

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var context: UninstallContext?
    @ObservationIgnored private var planner: UninstallPlanner?
    @ObservationIgnored private var config = RampConfig()
    @ObservationIgnored private var initialized = false

    /// Typed confirmation word (sk `ODINSTALOVAT`, en `UNINSTALL`).
    static var confirmationWord: String { String(localized: "ODINSTALOVAT") }

    var canConfirm: Bool {
        phase == .ready && (plan?.isExecutable ?? false)
            && confirmation.trimmingCharacters(in: .whitespaces) == Self.confirmationWord
    }

    var isFakeHome: Bool { context?.isFakeHome ?? false }

    static var allowFakeHome: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Never trash a development build (DerivedData / Build/Products) or anything while using a fake home.
    private func mayTrashApp(_ context: UninstallContext) -> Bool {
        let path = Bundle.main.bundleURL.path(percentEncoded: false)
        return !context.isFakeHome && !path.contains("/DerivedData/") && !path.contains("/Build/Products/")
    }

    func preparePlan() async {
        guard let app, phase != .running, phase != .finished else { return }
        phase = .planning
        config = (try? await app.stack.currentConfig()) ?? RampConfig()
        let ctx = UninstallContext.live(paths: app.paths, config: config, appBundle: Bundle.main.bundleURL,
                                        allowFakeHome: Self.allowFakeHome)
        context = ctx
        mysqlAvailable = ctx.mysqlDumpable
        if !initialized {
            initialized = true
            if !mysqlAvailable { dumpDatabases = false }
        }
        let options = UninstallOptions(
            dumpDatabases: dumpDatabases && mysqlAvailable,
            dumpDirectory: ctx.home.appending(path: "Desktop", directoryHint: .isDirectory),
            removeHostsBlock: removeHostsBlock, moveAppToTrash: mayTrashApp(ctx),
            unregisterHelper: !ctx.isFakeHome, unregisterLoginItem: !ctx.isFakeHome)
        // Sizing walks the data directories (can be 200+ GB) — off the main actor.
        let (newPlanner, newPlan) = await Task.detached(priority: .userInitiated) {
            let p = UninstallPlanner(context: ctx)
            return (p, p.plan(options: options))
        }.value
        planner = newPlanner
        plan = newPlan
        phase = .ready
    }

    func run() async {
        guard canConfirm, let app, let plan, let planner, let context else { return }
        phase = .running
        statuses = [:]
        // Fake home (DEBUG smoke): never the real /etc/hosts — only a user-owned `RAMP_HOSTS_FILE`, else the step
        // fails with a warning.
        var hosts: (any HostsSyncing)? = app.hostsHelper.syncer
        if context.isFakeHome {
            let file = ProcessInfo.processInfo.environment["RAMP_HOSTS_FILE"] ?? ""
            hosts = file.hasPrefix("/") ? DirectHostsSync(path: URL(filePath: file)) : nil
        }
        let actions = LiveUninstallActions(paths: app.paths, config: config, stack: app.stack,
                                           hosts: hosts, systemIntegration: !context.isFakeHome)
        let uninstaller = Uninstaller(actions: actions, pathGuard: planner.pathGuard)
        let result = await uninstaller.execute(plan) { progress in
            Task { @MainActor [weak self] in self?.statuses[progress.stepID] = progress.status }
        }
        report = result
        statuses = result.statuses
        phase = .finished
    }

    func revealDump() {
        guard let url = report?.dumpFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
