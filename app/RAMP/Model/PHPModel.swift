import Foundation
import Observation
import RAMPCore

/// One installed PHP branch as shown in the PHP section.
struct PHPBranchInfo: Identifiable, Equatable {
    var branch: String
    var version: String
    var enabled: Bool
    /// FPM supervisor state (from `ServicesModel`), nil when the service is not known yet.
    var fpmState: ServiceState?
    var settings: PHPBranchSettings
    /// Catalog extensions the package ships.
    var available: Set<String>
    /// Effective-enabled extensions (load order).
    var enabledExtensions: [String]
    var usedByVhosts: Int

    var id: String { branch }
    /// JIT has no effect on 7.x (ignored by the generator).
    var supportsJIT: Bool { (PHPBranch(branch)?.major ?? 0) >= 8 }
}

/// Selection in the PHP section: the "Globálne" ini entry or one branch.
enum PHPSelection: Hashable {
    case global
    case branch(String)
}

/// "Odinštalovať verziu…" alert: `refusal == nil` → confirmation, else the reason it cannot be removed.
struct PHPUninstallRequest: Identifiable, Equatable {
    var branch: String
    var version: String
    var refusal: String?
    var id: String { branch }
}

/// Selected branch detail tab.
enum PHPDetailTab: Hashable {
    case settings, ini
}

/// PHP section state. Every change goes through `PHPManager` (validate → save → `php-fpm -t` + SIGUSR2 of
/// that branch only, rollback on rejection); never touches Apache or other branches.
@MainActor @Observable
final class PHPModel {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let manager: PHPManager

    var selection: PHPSelection?
    var detailTab: PHPDetailTab = .settings
    /// Transient success text ("PHP 8.3 znovu načítané"), auto-hidden after 3 s.
    private(set) var status: String?
    /// Inline per-branch hints (e.g. "FPM nebeží" after a clear action on a stopped branch).
    private(set) var hints: [String: String] = [:]
    /// Inline error under the "Verzia zapnutá" toggle (e.g. refused disable: default / phpMyAdmin / vhosts).
    private(set) var enableErrors: [String: String] = [:]
    /// Optimistic settings while a change is being applied; dropped (→ reverted to ramp.json) afterwards.
    private var optimistic: [String: PHPBranchSettings] = [:]
    private var available: [String: Set<String>] = [:]
    private var enabledExtensions: [String: [String]] = [:]
    /// Effective ini cache per `iniKey` ("global" / branch); invalidated after every mutation.
    private(set) var iniCache: [String: [IniDirective]] = [:]
    private(set) var iniErrors: [String: String] = [:]
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    // Versions (install / uninstall whole branches, PHPVersionsSheet)
    /// "Pridať verziu PHP…" sheet.
    var showVersionsSheet = false
    /// Manifest PHP branches with install state (highest first); empty until `loadOffers`.
    private(set) var offers: [PHPBranchOffer] = []
    private(set) var offersLoading = false
    private(set) var offersError: String?
    /// Last event of a running branch install (stage + bytes), per branch.
    private(set) var installing: [String: InstallProgress] = [:]
    private(set) var installErrors: [String: String] = [:]
    /// Pending "Odinštalovať verziu…": confirmation, or the reason it is refused.
    var uninstallRequest: PHPUninstallRequest?
    @ObservationIgnored private var manifest: Manifest?

    init(stack: StackController) {
        manager = PHPManager(stack: stack)
    }

    // MARK: Derived state

    private var config: RampConfig { app?.config ?? RampConfig() }

    /// Installed branches, highest first.
    var branches: [PHPBranchInfo] {
        let config = config
        let installed = config.installed["php"] ?? [:]
        let enabledBranches = installed.keys.filter { config.php.branches[$0]?.enabled ?? true }
            .compactMap(PHPBranch.init).sorted()
        let defaultBranch = config.apache.defaultPHP ?? enabledBranches.last?.description
        let rows = app?.services.rows ?? []
        return installed.keys.compactMap { b in PHPBranch(b).map { (b, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { b, _ in
                let settings = optimistic[b] ?? config.php.branches[b] ?? PHPBranchSettings()
                let used = config.vhosts.filter { ($0.phpBranch ?? defaultBranch) == b }.count
                return PHPBranchInfo(branch: b, version: installed[b]?.version ?? b, enabled: settings.enabled,
                                     fpmState: rows.first { $0.id == .phpFPM(b) }?.state, settings: settings,
                                     available: available[b] ?? [], enabledExtensions: enabledExtensions[b] ?? [],
                                     usedByVhosts: used)
            }
    }

    func info(_ branch: String) -> PHPBranchInfo? { branches.first { $0.branch == branch } }

    var globalOverrides: [String: String] { config.php.globalIniOverrides }

    func isBusy(_ branch: String) -> Bool {
        guard let busy = app?.busy else { return false }
        return busy.contains("php-\(branch)") || busy.contains("php-global")
    }

    var isGlobalBusy: Bool {
        guard let busy = app?.busy else { return false }
        return busy.contains { $0.hasPrefix("php-") }
    }

    func socketPath(_ branch: String) -> String { app?.paths.fpmSocket(branch: branch).path(percentEncoded: false) ?? "" }

    // MARK: Loading

    /// Reloads config + extension availability; selects the highest branch when nothing is selected.
    func refresh() async {
        await app?.reloadConfig()
        for b in (config.installed["php"] ?? [:]).keys {
            await loadExtensions(b)
        }
        if selection == nil || !isValid(selection) {
            selection = branches.first.map { .branch($0.branch) }
        }
    }

    private func isValid(_ selection: PHPSelection?) -> Bool {
        switch selection {
        case .global: true
        case .branch(let b): config.installed["php"]?[b] != nil
        case nil: false
        }
    }

    private func loadExtensions(_ branch: String) async {
        #if DEBUG
        if ScreenshotMode.isActive {
            (available[branch], enabledExtensions[branch]) = DemoData.extensions(branch: branch, config: config)
            return
        }
        #endif
        available[branch] = (try? await manager.availableExtensions(branch: branch)) ?? []
        enabledExtensions[branch] = (try? await manager.enabledExtensions(branch: branch)) ?? []
    }

    static func iniKey(_ selection: PHPSelection) -> String {
        switch selection {
        case .global: "global"
        case .branch(let b): b
        }
    }

    /// Effective ini for the selection, computed off the main actor and cached.
    func loadIni(_ selection: PHPSelection, force: Bool = false) async {
        let key = Self.iniKey(selection)
        guard force || iniCache[key] == nil else { return }
        do {
            switch selection {
            case .branch(let b):
                iniCache[key] = try await manager.effectiveIni(branch: b)
            case .global:
                // Base + global layer only: a branch name that has no per-branch overrides.
                let config = config
                guard let paths = app?.paths else { return }
                iniCache[key] = try await Task.detached {
                    try PHPIniLayers.effective(config: config, branch: "", paths: paths)
                }.value
            }
            iniErrors[key] = nil
        } catch {
            iniErrors[key] = Self.message(error)
        }
    }

    private func invalidateIni() {
        iniCache = [:]
        iniErrors = [:]
    }

    // MARK: Actions (bindings: optimistic, reverted on error)

    func setOPcache(_ branch: String, _ options: OPcacheOptions) {
        guard var s = info(branch)?.settings, s.opcache != options else { return }
        s.opcache = options
        apply(branch, optimistic: s) { try await $0.setOPcache(branch: branch, options) }
    }

    func setXdebug(_ branch: String, _ mode: XdebugMode) {
        guard var s = info(branch)?.settings, s.xdebug != mode else { return }
        s.xdebug = mode
        apply(branch, optimistic: s) { try await $0.setXdebug(branch: branch, mode: mode) }
    }

    func setExtension(_ branch: String, _ name: String, enabled: Bool) {
        guard var s = info(branch)?.settings else { return }
        s.extensions[name] = enabled
        enabledExtensions[branch] = enabled ? (enabledExtensions[branch] ?? []) + [name]
            : (enabledExtensions[branch] ?? []).filter { $0 != name }
        apply(branch, optimistic: s) { try await $0.setExtension(branch: branch, name: name, enabled: enabled) }
    }

    /// Whole branch on/off: disabled → its FPM stops, enabled → starts. A refused disable (`branchInUse`)
    /// is shown inline under the toggle; other failures go to the error banner.
    func setBranchEnabled(_ branch: String, _ enabled: Bool) {
        guard info(branch)?.enabled != enabled else { return }
        let key = "php-\(branch)"
        guard app?.busy.contains(key) != true else { return }
        app?.busy.insert(key)
        enableErrors[branch] = nil
        hints[branch] = nil
        let manager = manager
        Task {
            do {
                try await manager.setBranchEnabled(branch: branch, enabled: enabled)
                showStatus(enabled ? String(localized: "PHP \(branch) zapnuté") : String(localized: "PHP \(branch) vypnuté"))
            } catch let error as PHPManagerError {
                if case .branchInUse = error {
                    enableErrors[branch] = Self.enableMessage(error)
                } else {
                    handle(error, branch: branch)
                }
            } catch {
                handle(error, branch: branch)
            }
            await finish()
            await app?.services.refresh()
            app?.busy.remove(key)
        }
    }

    func clearEnableError(_ branch: String) { enableErrors[branch] = nil }

    /// Localized `branchInUse` text: why the branch cannot be disabled (first 5 vhost domains).
    static func enableMessage(_ error: PHPManagerError) -> String {
        guard case .branchInUse(let b, let isDefault, let pma, let vhosts) = error else { return message(error) }
        var reasons: [String] = []
        if isDefault { reasons.append(String(localized: "je predvolená verzia (Nastavenia)")) }
        if pma { reasons.append(String(localized: "beží na nej phpMyAdmin")) }
        if !vhosts.isEmpty {
            var list = vhosts.prefix(PHPManagerError.shownVhostDomains).joined(separator: ", ")
            if vhosts.count > PHPManagerError.shownVhostDomains { list += ", …" }
            reasons.append(String(localized: "používajú ju vhosty (\(vhosts.count)): \(list)"))
        }
        return String(localized: "PHP \(b) sa nedá vypnúť: \(reasons.joined(separator: "; "))")
    }

    static func isValidSize(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+[KMG]?\z"#, options: .regularExpression) != nil
    }

    /// Returns false (nothing applied) for an invalid size.
    @discardableResult
    func setAPCuSize(_ branch: String, _ size: String) -> Bool {
        let size = size.trimmingCharacters(in: .whitespaces)
        guard Self.isValidSize(size) else { return false }
        guard var s = info(branch)?.settings, s.apcu.shmSize != size else { return true }
        s.apcu = APCuOptions(shmSize: size)
        apply(branch, optimistic: s) { try await $0.setAPCu(branch: branch, APCuOptions(shmSize: size)) }
        return true
    }

    func clearOPcache(_ branch: String) {
        run(branch, success: String(localized: "OPcache pre PHP \(branch) vyčistená")) {
            try await $0.clearOPcache(branch: branch)
        }
    }

    func clearAPCu(_ branch: String) {
        run(branch, success: String(localized: "APCu pre PHP \(branch) vyčistené")) {
            try await $0.clearAPCu(branch: branch)
        }
    }

    /// Graceful FPM reload of the branch (SIGUSR2 via PHPManager, same mechanism as clearing the caches).
    func reload(_ branch: String) {
        run(branch, success: String(localized: "PHP \(branch) znovu načítané")) {
            try await $0.clearOPcache(branch: branch)
        }
    }

    /// ini override set/remove. Throws validation errors (for inline display in the sheet); FPM rejection
    /// and other apply errors are reported by the model (error banner) and also rethrown.
    func setIniOverride(scope: PHPIniScope, key: String, value: String?) async throws {
        if let value { try PHPIniLayers.validate(key: key, value: value) }
        let busyKey: String
        switch scope {
        case .global: busyKey = "php-global"
        case .branch(let b): busyKey = "php-\(b)"
        }
        let success: String
        switch scope {
        case .global: success = String(localized: "Všetky PHP verzie znovu načítané")
        case .branch(let b): success = String(localized: "PHP \(b) znovu načítané")
        }
        app?.busy.insert(busyKey)
        defer { app?.busy.remove(busyKey) }
        do {
            try await manager.setIniOverride(scope: scope, key: key, value: value)
            showStatus(success)
            await finish()
        } catch {
            await finish()
            if case .fpmRejected = error as? PHPManagerError { handle(error, branch: nil) }
            throw error
        }
    }

    // MARK: Internals

    private func apply(_ branch: String, optimistic settings: PHPBranchSettings,
                       _ body: @escaping @Sendable (PHPManager) async throws -> Void) {
        optimistic[branch] = settings
        run(branch, success: String(localized: "PHP \(branch) znovu načítané"), body)
    }

    private func run(_ branch: String, success: String,
                     _ body: @escaping @Sendable (PHPManager) async throws -> Void) {
        let key = "php-\(branch)"
        guard app?.busy.contains(key) != true else { return }
        app?.busy.insert(key)
        hints[branch] = nil
        let manager = manager
        Task {
            do {
                try await body(manager)
                showStatus(success)
            } catch {
                handle(error, branch: branch)
            }
            optimistic[branch] = nil
            await loadExtensions(branch)
            await finish()
            app?.busy.remove(key)
        }
    }

    private func finish() async {
        await app?.reloadConfig()
        invalidateIni()
        if case .some(let selection) = selection, detailTab == .ini || selection == .global {
            await loadIni(selection)
        }
    }

    private func handle(_ error: any Error, branch: String?) {
        switch error as? PHPManagerError {
        case .fpmRejected(let b, let output)?:
            app?.report(title: String(localized: "PHP \(b) odmietlo konfiguráciu — vrátené späť"), message: output)
        case .notRunning(let b)?:
            hints[b] = String(localized: "FPM nebeží")
        default:
            app?.report(title: String(localized: "Zmena PHP \(branch ?? "") zlyhala"), message: Self.message(error))
        }
    }

    private func showStatus(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    // MARK: Versions (install / uninstall)

    /// Loads the configured manifest once (`force` refetches) and derives the offers from ramp.json.
    func loadOffers(force: Bool = false) async {
        guard !offersLoading else { return }
        if let manifest, !force {
            recomputeOffers(manifest)
            return
        }
        offersLoading = true
        defer { offersLoading = false }
        do {
            let resolved = try await Self.loadManifest(manager)
            manifest = resolved
            offersError = nil
            recomputeOffers(resolved)
        } catch {
            offersError = Self.message(error)
        }
    }

    private nonisolated static func loadManifest(_ manager: PHPManager) async throws -> Manifest {
        guard let url = try await manager.store.load().manifestURL else { throw PHPManagerError.noManifest }
        return try await ManifestLoader.load(url)
    }

    private func recomputeOffers(_ manifest: Manifest) {
        guard let paths = app?.paths else { return }
        offers = PHPManager.offers(manifest: manifest, config: config, paths: paths)
    }

    /// Manifest support phase of an installed branch (nil until the manifest is loaded / not published).
    func offer(_ branch: String) -> PHPBranchOffer? { offers.first { $0.branch == branch } }

    func isInstalling(_ branch: String) -> Bool { installing[branch] != nil }

    func install(_ branch: String) {
        Task { await installBranch(branch) }
    }

    /// Download + install + enable + start the branch's FPM. Returns true on success (MAMP import re-plans).
    @discardableResult
    func installBranch(_ branch: String) async -> Bool {
        guard installing[branch] == nil else { return false }
        installErrors[branch] = nil
        installing[branch] = InstallProgress(component: "php", branch: branch, stage: .downloading)
        let manager = manager
        let manifest = manifest
        let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
        let observer = Task { [weak self] in
            for await event in progress where self?.installing[branch] != nil {
                if case .installed = event.stage { continue }
                if case .failed = event.stage { continue }
                self?.installing[branch] = event
            }
        }
        var ok = false
        do {
            try await manager.installBranch(branch, manifest: manifest, progress: continuation)
            ok = true
        } catch {
            installErrors[branch] = Self.message(error)
        }
        await observer.value
        installing[branch] = nil
        await afterBranchSetChange()
        if ok {
            await loadExtensions(branch)
            showStatus(String(localized: "PHP \(branch) nainštalované"))
        }
        return ok
    }

    /// Context menu / sheet: asks for confirmation, or explains why the branch cannot be removed.
    func requestUninstall(_ branch: String) {
        guard let paths = app?.paths else { return }
        let blocker = PHPManager.uninstallBlocker(config: config, paths: paths, branch: branch)
        uninstallRequest = PHPUninstallRequest(branch: branch, version: config.installed["php"]?[branch]?.version ?? branch,
                                               refusal: blocker.map(Self.uninstallMessage))
    }

    func confirmUninstall() {
        guard let request = uninstallRequest, request.refusal == nil else {
            uninstallRequest = nil
            return
        }
        uninstallRequest = nil
        let branch = request.branch
        let key = "php-\(branch)"
        guard app?.busy.contains(key) != true else { return }
        app?.busy.insert(key)
        let manager = manager
        Task {
            do {
                try await manager.uninstallBranch(branch)
                showStatus(String(localized: "PHP \(branch) odinštalované"))
            } catch let error as PHPManagerError {
                if case .uninstallBlocked = error {
                    uninstallRequest = PHPUninstallRequest(branch: branch, version: request.version,
                                                           refusal: Self.uninstallMessage(error))
                } else {
                    app?.report(title: String(localized: "Odinštalovanie PHP \(branch) zlyhalo"), message: Self.message(error))
                }
            } catch {
                app?.report(title: String(localized: "Odinštalovanie PHP \(branch) zlyhalo"), message: Self.message(error))
            }
            available[branch] = nil
            enabledExtensions[branch] = nil
            optimistic[branch] = nil
            await afterBranchSetChange()
            app?.busy.remove(key)
        }
    }

    private func afterBranchSetChange() async {
        await finish()
        if !isValid(selection) { selection = branches.first.map { .branch($0.branch) } }
        if let manifest { recomputeOffers(manifest) }
        await app?.services.refresh()
    }

    /// Localized `uninstallBlocked` text: why the branch cannot be uninstalled (first 5 vhost domains).
    static func uninstallMessage(_ error: PHPManagerError) -> String {
        guard case .uninstallBlocked(let b, let isDefault, let pma, let vhosts) = error else { return message(error) }
        var reasons: [String] = []
        if isDefault { reasons.append(String(localized: "je predvolená verzia (Nastavenia)")) }
        if pma { reasons.append(String(localized: "beží na nej phpMyAdmin")) }
        if !vhosts.isEmpty {
            var list = vhosts.prefix(PHPManagerError.shownVhostDomains).joined(separator: ", ")
            if vhosts.count > PHPManagerError.shownVhostDomains { list += ", …" }
            reasons.append(String(localized: "používajú ju vhosty (\(vhosts.count)): \(list)"))
        }
        return String(localized: "PHP \(b) sa nedá odinštalovať: \(reasons.joined(separator: "; "))")
    }

    /// `2022-11-28` → localized numeric date ("28. 11. 2022"); the raw string when unparsable.
    static func formatDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}
