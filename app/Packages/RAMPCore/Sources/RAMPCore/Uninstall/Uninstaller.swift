import Darwin
import Foundation

// Uninstall (plan 07-07): dry-run planner + executor. Every deletion goes through `UninstallPathGuard`;
// the privileged/system side effects (services, dump, hosts, helper, login item, prefs, Trash) sit behind
// `UninstallActions` so tests run against a fake home with fakes only.

public struct UninstallOptions: Sendable, Equatable {
    public var dumpDatabases: Bool
    public var dumpDirectory: URL
    public var removeHostsBlock: Bool
    public var moveAppToTrash: Bool
    /// App only — rampctl cannot reach SMAppService for the app bundle.
    public var unregisterHelper: Bool
    public var unregisterLoginItem: Bool

    public init(dumpDatabases: Bool, dumpDirectory: URL, removeHostsBlock: Bool = true,
                moveAppToTrash: Bool = true, unregisterHelper: Bool = true, unregisterLoginItem: Bool = true) {
        self.dumpDatabases = dumpDatabases
        self.dumpDirectory = dumpDirectory
        self.removeHostsBlock = removeHostsBlock
        self.moveAppToTrash = moveAppToTrash
        self.unregisterHelper = unregisterHelper
        self.unregisterLoginItem = unregisterLoginItem
    }
}

/// What the planner needs to know about the machine. `home`/`library` are injectable (fake home in tests
/// and in DEBUG smoke runs via `RAMP_UNINSTALL_FAKE_HOME`).
public struct UninstallContext: Sendable {
    public var paths: Paths
    public var home: URL
    public var library: URL
    public var bundleID: String
    public var config: RampConfig
    /// Running app bundle (`Bundle.main.bundleURL`); `nil` for rampctl.
    public var appBundle: URL?
    public var now: Date

    public init(paths: Paths, home: URL, library: URL, bundleID: String = "sk.tyron.ramp",
                config: RampConfig, appBundle: URL? = nil, now: Date = Date()) {
        self.paths = paths
        self.home = home
        self.library = library
        self.bundleID = bundleID
        self.config = config
        self.appBundle = appBundle
        self.now = now
    }

    /// Real home, or `RAMP_UNINSTALL_FAKE_HOME` when `allowFakeHome` (DEBUG app builds, rampctl).
    public static func live(paths: Paths, config: RampConfig, appBundle: URL?, allowFakeHome: Bool,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> UninstallContext {
        let home: URL
        if allowFakeHome, let fake = environment["RAMP_UNINSTALL_FAKE_HOME"], fake.hasPrefix("/") {
            home = URL(filePath: fake, directoryHint: .isDirectory)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return UninstallContext(paths: paths, home: home,
                                library: home.appending(path: "Library", directoryHint: .isDirectory),
                                config: config, appBundle: appBundle)
    }

    public var isFakeHome: Bool {
        UninstallPathGuard.canonical(home.path(percentEncoded: false))
            != UninstallPathGuard.canonical(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
    }

    public var vhostDocroots: [String] { config.vhosts.map(\.docroot).filter { !$0.isEmpty } }

    public var mysqlDumpable: Bool {
        config.installed["mysql"]?[config.mysql.branch] != nil && config.mysql.initialized
    }

    public func makeGuard() -> UninstallPathGuard {
        UninstallPathGuard(home: home, library: library, paths: paths, bundleID: bundleID,
                           deniedRoots: UninstallPathGuard.defaultDeniedRoots(home: home, docroots: vhostDocroots))
    }
}

public enum UninstallStepKind: Sendable, Equatable {
    case acquireLock
    case stopServices
    case dumpDatabases(URL)
    case removeHostsBlock
    case unregisterHelper
    case unregisterLoginItem
    /// Guarded canonical path + size in bytes (allocated, symlinks not followed).
    case delete(URL, bytes: Int64)
    case removePreferencesDomain(String)
    case trashApp(URL)
    /// Terminal integration: remove the `# >>> RAMP >>>` PATH blocks and restore the MAMP lines RAMP disabled
    /// (only those carrying `ShellIntegration.disabledPrefix`) in `home`'s shell startup files.
    case removeShellIntegration(home: URL)
}

public struct UninstallStep: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: UninstallStepKind
    public var description: String
}

public struct UninstallPlan: Sendable, Equatable {
    public var steps: [UninstallStep]
    /// Guard refusals — non-empty means nothing will run.
    public var refusals: [String]
    /// Informational (skipped steps).
    public var notes: [String]
    /// Project folders that stay untouched.
    public var keptDocroots: [String]

    public var isExecutable: Bool { refusals.isEmpty }
    public var deletions: [(url: URL, bytes: Int64)] {
        steps.compactMap { if case .delete(let u, let b) = $0.kind { (u, b) } else { nil } }
    }
    public var totalBytes: Int64 { deletions.reduce(0) { $0 + $1.bytes } }
    public var dumpFile: URL? {
        steps.lazy.compactMap { if case .dumpDatabases(let u) = $0.kind { u } else { nil } }.first
    }

    /// Plain-text rendering (rampctl `uninstall --dry-run`).
    public func render() -> String {
        var lines: [String] = []
        for s in steps { lines.append(String(format: "%2d. ", s.id) + s.description) }
        lines.append("Total to delete: \(UninstallPlanner.formatBytes(totalBytes))")
        if !keptDocroots.isEmpty {
            lines.append("Project folders are never deleted:")
            lines += keptDocroots.map { "   keep \($0)" }
        }
        lines += notes.map { "note: \($0)" }
        if !refusals.isEmpty {
            lines.append("REFUSED — nothing will be done:")
            lines += refusals.map { "   \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

public struct UninstallPlanner: Sendable {
    public let context: UninstallContext
    public let pathGuard: UninstallPathGuard

    public init(context: UninstallContext) {
        self.context = context
        pathGuard = context.makeGuard()
    }

    public func plan(options: UninstallOptions) -> UninstallPlan {
        var kinds: [(UninstallStepKind, String)] = []
        var refusals = pathGuard.refusedRoots
        var notes: [String] = []
        let lib = context.library

        kinds.append((.acquireLock, "Acquire the maintenance lock"))
        kinds.append((.stopServices, "Stop all services (Apache, PHP-FPM, MySQL, Redis, Elasticsearch)"))

        if options.dumpDatabases {
            if context.mysqlDumpable {
                let file = Self.dumpFile(in: options.dumpDirectory, now: context.now)
                if case .success = pathGuard.check(options.dumpDirectory) {
                    refusals.append("Backup directory \(options.dumpDirectory.path(percentEncoded: false)) "
                                    + "would be deleted by the uninstall — choose another one")
                }
                kinds.append((.dumpDatabases(file),
                              "Back up all MySQL databases (mysqldump --all-databases) to \(file.path(percentEncoded: false))"))
            } else {
                notes.append("MySQL is not installed/initialized — no database backup")
            }
        }
        if options.removeHostsBlock {
            kinds.append((.removeHostsBlock, "Remove the # RAMP block from /etc/hosts"))
        }
        if options.unregisterHelper {
            kinds.append((.unregisterHelper, "Unregister the hosts helper daemon (sk.tyron.ramp.hostshelper)"))
        } else {
            notes.append("Hosts helper daemon is not unregistered here (app only)")
        }
        if options.unregisterLoginItem {
            kinds.append((.unregisterLoginItem, "Remove RAMP from Login Items"))
        } else {
            notes.append("Login item is not removed here (app only)")
        }

        // Terminal integration (~/.ramp/bin shims + PATH blocks + disabled MAMP lines).
        let shell = ShellIntegration(home: context.home)
        let shellStatus = shell.status()
        if shellStatus.anyBlock || !shellStatus.disabledLines.isEmpty {
            let files = shellStatus.files.filter(\.hasBlock).map { $0.file.lastPathComponent }
            var text = "Remove the RAMP PATH block from ~/" + (files.isEmpty ? "(none)" : files.joined(separator: ", ~/"))
            if !shellStatus.disabledLines.isEmpty {
                text += "; re-enable \(shellStatus.disabledLines.count) MAMP line(s) RAMP disabled"
            }
            kinds.append((.removeShellIntegration(home: context.home), text))
        }

        // Deletions: children first (so a failure never leaves a half-deleted root unnoticed), then the root.
        var seen = Set<String>()
        let roots = [context.paths.root, context.paths.logs,
                     lib.appending(path: "Caches/\(context.bundleID)", directoryHint: .isDirectory),
                     lib.appending(path: "HTTPStorages/\(context.bundleID)", directoryHint: .isDirectory)]
        if pathGuard.refusedRoots.isEmpty {
            for root in roots {
                let rootPath = root.path(percentEncoded: false)
                guard Self.exists(rootPath), seen.insert(UninstallPathGuard.canonical(rootPath)).inserted else { continue }
                let children = ((try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []).sorted()
                for name in children {
                    let child = root.appending(path: name, directoryHint: .notDirectory)
                    switch pathGuard.check(child) {
                    case .success(let url):
                        let size = Self.allocatedSize(url)
                        kinds.append((.delete(url, bytes: size),
                                      "Delete \(url.path(percentEncoded: false)) (\(Self.formatBytes(size)))"))
                    case .failure(let error):
                        refusals.append(error.localizedDescription)
                    }
                }
                switch pathGuard.check(root) {
                case .success(let url):
                    kinds.append((.delete(url, bytes: 0), "Delete \(url.path(percentEncoded: false))"))
                case .failure(let error):
                    refusals.append(error.localizedDescription)
                }
            }
        }

        // ~/.ramp: managed shims one by one; the directories only when nothing foreign is left in them.
        if pathGuard.refusedRoots.isEmpty, Self.exists(shell.rampDir.path(percentEncoded: false)) {
            let writer = CLIShimWriter(shimDir: shell.shimDir)
            let managed = writer.managedNames()
            for name in managed {
                let url = shell.shimDir.appending(path: name, directoryHint: .notDirectory)
                switch pathGuard.check(url) {
                case .success(let u): kinds.append((.delete(u, bytes: Self.allocatedSize(u)), "Delete terminal shim \(u.path(percentEncoded: false))"))
                case .failure(let error): refusals.append(error.localizedDescription)
                }
            }
            let fm = FileManager.default
            let binLeft = ((try? fm.contentsOfDirectory(atPath: shell.shimDir.path(percentEncoded: false))) ?? [])
                .filter { !managed.contains($0) }
            let rampLeft = ((try? fm.contentsOfDirectory(atPath: shell.rampDir.path(percentEncoded: false))) ?? [])
                .filter { $0 != "bin" }
            if binLeft.isEmpty && rampLeft.isEmpty {
                for dir in [shell.shimDir, shell.rampDir] where Self.exists(dir.path(percentEncoded: false)) {
                    switch pathGuard.check(dir) {
                    case .success(let u): kinds.append((.delete(u, bytes: 0), "Delete \(u.path(percentEncoded: false))"))
                    case .failure(let error): refusals.append(error.localizedDescription)
                    }
                }
            } else {
                notes.append("\(shell.rampDir.path(percentEncoded: false)) keeps files RAMP did not create: "
                             + (binLeft.map { "bin/\($0)" } + rampLeft).joined(separator: ", "))
            }
        }

        let prefs = lib.appending(path: "Preferences/\(context.bundleID).plist", directoryHint: .notDirectory)
        kinds.append((.removePreferencesDomain(context.bundleID), "Remove preferences domain \(context.bundleID)"))
        if Self.exists(prefs.path(percentEncoded: false)) {
            switch pathGuard.check(prefs) {
            case .success(let url):
                kinds.append((.delete(url, bytes: Self.allocatedSize(url)), "Delete \(url.path(percentEncoded: false))"))
            case .failure(let error):
                refusals.append(error.localizedDescription)
            }
        }

        if options.moveAppToTrash {
            if let app = context.appBundle, app.pathExtension == "app",
               Bundle(url: app)?.bundleIdentifier == context.bundleID {
                kinds.append((.trashApp(app), "Move \(app.path(percentEncoded: false)) to the Trash"))
            } else {
                notes.append("App bundle is not moved to the Trash (not running from a RAMP.app bundle)")
            }
        }

        let steps = kinds.enumerated().map { UninstallStep(id: $0.offset + 1, kind: $0.element.0, description: $0.element.1) }
        return UninstallPlan(steps: steps, refusals: refusals, notes: notes,
                             keptDocroots: context.vhostDocroots.sorted())
    }

    // MARK: Helpers

    static func dumpFile(in dir: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let stem = "RAMP-backup-\(f.string(from: now))"
        var url = dir.appending(path: "\(stem).sql", directoryHint: .notDirectory)
        var n = 2
        while exists(url.path(percentEncoded: false)) {
            url = dir.appending(path: "\(stem)-\(n).sql", directoryHint: .notDirectory)
            n += 1
        }
        return url
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Allocated bytes below `url` without following symlinks.
    static func allocatedSize(_ url: URL) -> Int64 {
        var st = stat()
        let path = url.path(percentEncoded: false)
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_blocks) * 512 }
        var total = Int64(st.st_blocks) * 512
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                  errorHandler: { _, _ in true }) {
            for case let item as URL in e {
                let v = try? item.resourceValues(forKeys: Set(keys))
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Side effects

/// Everything the executor does besides deleting guarded paths. Live: `LiveUninstallActions`.
public protocol UninstallActions: Sendable {
    /// Returns the release closure. Throws `UninstallError.busy` when another maintenance task runs.
    func acquireLock() async throws -> @Sendable () async -> Void
    func stopServices() async
    /// Must leave a complete dump (`-- Dump completed`) at `url` or throw (and leave no partial file).
    func dumpAllDatabases(to url: URL) async throws
    func removeHostsBlock() async throws
    func unregisterHelper() async throws
    func unregisterLoginItem() async throws
    func removePreferencesDomain(_ bundleID: String) async
    func moveToTrash(_ url: URL) async throws
}

public enum UninstallStepStatus: Sendable, Equatable {
    case running
    case done
    case skipped(String)
    case failed(String)
}

public struct UninstallProgress: Sendable, Equatable {
    public var stepID: Int
    public var status: UninstallStepStatus
}

public struct UninstallReport: Sendable, Equatable {
    /// Set when the run stopped before any deletion (refusal, lock, dump failure).
    public var aborted: String?
    public var dumpFile: URL?
    public var deleted: [URL] = []
    public var warnings: [String] = []
    /// Commands / places for manual cleanup of failed non-blocking steps.
    public var manualSteps: [String] = []
    public var appTrashed = false
    public var statuses: [Int: UninstallStepStatus] = [:]

    public var succeeded: Bool { aborted == nil && warnings.isEmpty }
}

public struct Uninstaller: Sendable {
    public let actions: any UninstallActions
    public let pathGuard: UninstallPathGuard

    public init(actions: any UninstallActions, pathGuard: UninstallPathGuard) {
        self.actions = actions
        self.pathGuard = pathGuard
    }

    public static let manualHostsCleanup = "sudo sed -i '' '/^# RAMP BEGIN/,/^# RAMP END/d' /etc/hosts"
    public static let manualHelperCleanup = "sudo launchctl bootout system/sk.tyron.ramp.hostshelper"
    public static let manualShellCleanup = "Remove the '# >>> RAMP >>>' … '# <<< RAMP <<<' block from ~/.zprofile, ~/.zshrc, "
        + "~/.bash_profile, ~/.profile and drop the '# [RAMP disabled MAMP] ' prefix from MAMP lines"
    public static let manualLoginItemCleanup = "System Settings › General › Login Items & Extensions → remove RAMP"

    public func execute(_ plan: UninstallPlan,
                        progress: @Sendable (UninstallProgress) -> Void = { _ in }) async -> UninstallReport {
        var report = UninstallReport()
        func mark(_ step: UninstallStep, _ status: UninstallStepStatus) {
            report.statuses[step.id] = status
            progress(UninstallProgress(stepID: step.id, status: status))
        }

        guard plan.isExecutable else {
            report.aborted = UninstallError.planNotExecutable(plan.refusals).localizedDescription
            return report
        }
        // Re-validate every deletion before touching anything: one refusal aborts the whole run.
        for (url, _) in plan.deletions {
            if case .failure(let error) = pathGuard.check(url) {
                report.aborted = error.localizedDescription
                return report
            }
        }

        var release: (@Sendable () async -> Void)?
        for step in plan.steps {
            mark(step, .running)
            switch step.kind {
            case .acquireLock:
                do {
                    release = try await actions.acquireLock()
                    mark(step, .done)
                } catch {
                    mark(step, .failed(Self.message(error)))
                    report.aborted = Self.message(error)
                    return report
                }
            case .stopServices:
                await actions.stopServices()
                mark(step, .done)
            case .dumpDatabases(let url):
                do {
                    try await actions.dumpAllDatabases(to: url)
                    report.dumpFile = url
                    mark(step, .done)
                } catch {
                    // User data first: no dump → nothing is deleted.
                    let why = UninstallError.dumpFailed(Self.message(error)).localizedDescription
                    mark(step, .failed(why))
                    report.aborted = why
                    await release?()
                    return report
                }
            case .removeHostsBlock:
                do {
                    try await actions.removeHostsBlock()
                    mark(step, .done)
                } catch {
                    nonBlockingFailure(step, error, manual: Self.manualHostsCleanup, &report)
                    mark(step, .failed(Self.message(error)))
                }
            case .unregisterHelper:
                do {
                    try await actions.unregisterHelper()
                    mark(step, .done)
                } catch {
                    nonBlockingFailure(step, error, manual: Self.manualHelperCleanup, &report)
                    mark(step, .failed(Self.message(error)))
                }
            case .unregisterLoginItem:
                do {
                    try await actions.unregisterLoginItem()
                    mark(step, .done)
                } catch {
                    nonBlockingFailure(step, error, manual: Self.manualLoginItemCleanup, &report)
                    mark(step, .failed(Self.message(error)))
                }
            case .delete(let url, _):
                switch Self.removeGuarded(url, pathGuard) {
                case .success(let removed):
                    if removed { report.deleted.append(url) }
                    mark(step, removed ? .done : .skipped("already gone"))
                case .failure(let error):
                    report.warnings.append(Self.message(error))
                    mark(step, .failed(Self.message(error)))
                }
            case .removePreferencesDomain(let id):
                await actions.removePreferencesDomain(id)
                mark(step, .done)
            case .removeShellIntegration(let home):
                do {
                    try ShellIntegration(home: home).uninstall(restoreMAMP: true)
                    mark(step, .done)
                } catch {
                    nonBlockingFailure(step, error, manual: Self.manualShellCleanup, &report)
                    mark(step, .failed(Self.message(error)))
                }
            case .trashApp(let url):
                do {
                    try await actions.moveToTrash(url)
                    report.appTrashed = true
                    mark(step, .done)
                } catch {
                    report.warnings.append("Moving RAMP.app to the Trash failed: \(Self.message(error))")
                    report.manualSteps.append("Drag \(url.path(percentEncoded: false)) to the Trash")
                    mark(step, .failed(Self.message(error)))
                }
            }
        }
        await release?()
        return report
    }

    private func nonBlockingFailure(_ step: UninstallStep, _ error: any Error, manual: String,
                                    _ report: inout UninstallReport) {
        report.warnings.append("\(step.description): \(Self.message(error))")
        report.manualSteps.append(manual)
    }

    /// Guard check at the moment of deletion (TOCTOU), then `unlink` for links/files, `removeItem` for
    /// directories (never follows symlinks inside). `false` = nothing there.
    static func removeGuarded(_ url: URL, _ pathGuard: UninstallPathGuard) -> Result<Bool, UninstallError> {
        let checked: URL
        switch pathGuard.check(url) {
        case .success(let u): checked = u
        case .failure(let e): return .failure(e)
        }
        let path = checked.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { return .success(false) }
        let type = st.st_mode & S_IFMT
        if type == S_IFDIR {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                return .failure(.unresolvable("\(path): \(error.localizedDescription)"))
            }
        } else if unlink(path) != 0 {
            return .failure(.unresolvable("\(path): \(String(cString: strerror(errno)))"))
        }
        return .success(true)
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
