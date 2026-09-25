import Foundation
import Observation
import RAMPCore

/// Detect-only update check (05-05): manifest × `config.installed` → `UpdateCheck.available`. Feeds the
/// menu-bar badge; never downloads or applies anything (Phase 7 does that). Errors never become alerts —
/// the previous result is kept and `lastError` is shown only in Settings.
/// 07-02: `apply` gets the full plan after each check (auto-applies PHP patches, one-click apply).
@MainActor @Observable
final class UpdatesModel {
    @ObservationIgnored weak var app: AppModel? {
        didSet { apply.app = app }
    }
    /// Apply side (07-02).
    let apply = UpdateApplyModel()

    private(set) var updates: [PackageUpdate] = []
    private(set) var lastChecked: Date?
    private(set) var lastError: String?
    private(set) var isChecking = false

    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Periodic check (launch, then every `config.updates.checkIntervalHours`, default 24 h).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                let hours = max(1, self.app?.config.updates.checkIntervalHours ?? 24)
                try? await Task.sleep(for: .seconds(hours * 3600))
            }
        }
    }

    /// Cancels the periodic loop (app quit); no update starts afterwards.
    func stop() {
        loop?.cancel()
        loop = nil
        apply.quit()
    }

    /// Badge list from an already loaded manifest after an update was applied (07-02; no network).
    func recompute(using manifest: Manifest) {
        guard let app else { return }
        updates = UpdateCheck.available(manifest: manifest, installed: app.config.installed)
    }

    /// New interval (07-02): check now and continue with the new period.
    func restart() {
        loop?.cancel()
        loop = nil
        start()
    }

    func check() async {
        guard !isChecking, let app else { return }
        let config = app.config
        // Same source as installation: ramp.json `manifestURL`, dev fallback `RAMP_DEV_MANIFEST`; none → no updates.
        let dev = ProcessInfo.processInfo.environment["RAMP_DEV_MANIFEST"].flatMap { URL(string: $0) }
        guard let url = config.manifestURL ?? dev else {
            updates = []
            lastError = nil
            return
        }
        isChecking = true
        defer { isChecking = false }
        let installed = config.installed
        do {
            let (manifest, available) = try await Task.detached {
                let manifest = try await ManifestLoader.load(url)
                return (manifest, UpdateCheck.available(manifest: manifest, installed: installed))
            }.value
            updates = available
            lastChecked = .now
            lastError = nil
            apply.planned(manifest: manifest)   // 07-02
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
