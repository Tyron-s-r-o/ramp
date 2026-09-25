import Foundation
import Observation
import RAMPCore

/// Apply side of updates (plan 07-02), owned by `UpdatesModel`: full `UpdatePlan` (automatic / offered / new branch /
/// migration), automatic PHP patches after each check, one-click apply, per-item progress + last outcome, a menu-bar
/// note for automatic updates and persistent warnings for failures / rollbacks. Never applies while quitting.
@MainActor @Observable
final class UpdateApplyModel {
    @ObservationIgnored weak var app: AppModel?

    private(set) var plan = UpdatePlan(items: [])
    /// Running step per item (`UpdateApplyModel.key`).
    private(set) var progress: [String: UpdateProgress] = [:]
    /// Last outcome per item key (kept until the next check replaces the plan entry).
    private(set) var outcomes: [String: UpdateOutcome] = [:]
    /// In-app note in the menu-bar header ("PHP 8.3 aktualizované na 8.3.36").
    private(set) var note: String?
    /// Persistent warning rows (failures / rollbacks) until dismissed.
    private(set) var warnings: [String] = []
    private(set) var isApplying = false

    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var manifest: Manifest?
    @ObservationIgnored private var cachedService: UpdateService?
    /// `key@version` of automatic updates that failed / rolled back this session — not retried automatically.
    @ObservationIgnored private var failedAutomatic: Set<String> = []
    /// Item whose progress events are currently accepted (late events of a finished run are dropped).
    @ObservationIgnored private var inFlight: String?

    private var service: UpdateService? {
        if let cachedService { return cachedService }
        guard let app else { return nil }
        let created = UpdateService(stack: app.stack)
        cachedService = created
        return created
    }

    static func key(_ item: UpdateItem) -> String { "\(item.component)/\(item.branch)" }

    private var pendingAutomatic: [UpdateItem] {
        plan.automatic.filter { !failedAutomatic.contains("\(Self.key($0))@\($0.to)") }
    }

    var offered: [UpdateItem] { plan.items.filter { $0.kind == .offered || $0.kind == .automatic } }

    /// After a successful check: new plan; automatic items are applied in the background.
    func planned(manifest: Manifest) {
        self.manifest = manifest
        guard let app else { return }
        plan = UpdatePolicy.plan(manifest: manifest, config: app.config)
        guard !pendingAutomatic.isEmpty, !isQuitting, !isApplying else { return }
        Task { await applyAutomatic() }
    }

    /// App quit: nothing new starts (a running update finishes or is cut off by the stop).
    func quit() { isQuitting = true }

    func applyAutomatic() async {
        guard let app, let service, !isQuitting, !isApplying else { return }
        guard await app.stack.maintenance.current == nil else { return }   // import / uninstall / dump running
        var done: [String] = []
        for item in pendingAutomatic where !isQuitting {
            let outcome = await run(item, service: service)
            if case .updated(_, let to) = outcome {
                done.append(String(localized: "\(Self.displayName(item)) aktualizované na \(to)"))
            } else {
                failedAutomatic.insert("\(Self.key(item))@\(item.to)")
            }
        }
        if !done.isEmpty { note = done.joined(separator: "\n") }
    }

    func apply(_ item: UpdateItem) async {
        guard let service, !isQuitting, !isApplying else { return }
        _ = await run(item, service: service)
    }

    /// Every offered + automatic item, sequentially.
    func applyAll() async {
        guard let service, !isQuitting, !isApplying else { return }
        for item in offered where !isQuitting { _ = await run(item, service: service) }
    }

    func dismissNote() { note = nil }
    func dismissWarning(_ text: String) { warnings.removeAll { $0 == text } }

    // MARK: Settings (ramp.json `updates`)

    func setInterval(_ hours: Int) async {
        let range = UpdateSettings.intervalRange
        let clamped = min(max(hours, range.lowerBound), range.upperBound)
        await mutate { $0.updates.checkIntervalHours = clamped }
        app?.updates.restart()
    }

    func setAutoApplyPHPPatches(_ on: Bool) async { await mutate { $0.updates.autoApplyPHPPatches = on } }
    func setDumpBeforeMySQLPatch(_ on: Bool) async { await mutate { $0.updates.dumpBeforeMySQLPatch = on } }

    private func mutate(_ change: @escaping @Sendable (inout RampConfig) -> Void) async {
        guard let app else { return }
        do {
            try await app.configStore.update(change)
            await app.reloadConfig()
            if let manifest { plan = UpdatePolicy.plan(manifest: manifest, config: app.config) }
        } catch {
            app.report(title: String(localized: "Nastavenia aktualizácií sa nepodarilo uložiť"), error: error)
        }
    }

    // MARK: Run

    private func run(_ item: UpdateItem, service: UpdateService) async -> UpdateOutcome {
        let key = Self.key(item)
        isApplying = true
        inFlight = key
        progress[key] = .waitingForLock
        let outcome = await service.apply(item, manifest: manifest) { [weak self] step in
            Task { @MainActor in
                guard let self, self.inFlight == key else { return }
                if case .finished = step { return }
                self.progress[key] = step
            }
        }
        inFlight = nil
        progress[key] = nil
        outcomes[key] = outcome
        isApplying = false
        switch outcome {
        case .updated:
            break
        case .rolledBack(let to, let reason):
            warnings.append(String(localized: "\(Self.displayName(item)): aktualizácia vrátená na \(to) – \(reason)"))
        case .failed:
            warnings.append(String(localized: "\(Self.displayName(item)): aktualizácia zlyhala – \(outcome.message)"))
        }
        if let app {
            await app.reloadConfig()
            if let manifest {
                plan = UpdatePolicy.plan(manifest: manifest, config: app.config)
                app.updates.recompute(using: manifest)
            }
        }
        return outcome
    }

    static func displayName(_ item: UpdateItem) -> String {
        let names = ["php": "PHP", "apache": "Apache", "mysql": "MySQL", "redis": "Redis",
                     "phpmyadmin": "phpMyAdmin", "elasticsearch": "Elasticsearch",
                     "elasticvue": "Elasticvue"]
        return "\(names[item.component] ?? item.component) \(item.branch)"
    }
}
