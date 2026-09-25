import Foundation
import Observation
import RAMPCore

/// Privileged hosts helper state (03-05): SMAppService registration / approval and the hosts sync used by
/// `VhostService` (helper when enabled, otherwise the administrator password prompt). Minimal menu hook;
/// the real UI comes with Phase 5.
@MainActor @Observable
final class HostsHelperModel {
    private(set) var status: HelperStatus = .notRegistered
    private(set) var lastSync: HostsSyncState?

    @ObservationIgnored let helper = HelperHostsSync()
    @ObservationIgnored let syncer: HostsSyncCoordinator
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(paths: Paths) {
        syncer = HostsSyncCoordinator(helper: helper, fallback: AdminPromptHostsSync(paths: paths))
    }

    var statusText: String {
        switch status {
        case .enabled: String(localized: "povolený")
        case .requiresApproval: String(localized: "čaká na schválenie")
        case .notRegistered: String(localized: "neregistrovaný")
        case .notFound: String(localized: "nenájdený v RAMP.app")
        }
    }

    func refreshStatus() async {
        #if DEBUG
        if ScreenshotMode.isActive { status = .enabled; return }
        #endif
        status = await helper.status
    }

    /// Registers the daemon (first time → "requires approval") and opens System Settings › Login Items so the
    /// user can switch RAMP on; then polls the status for two minutes (there is no callback API).
    func approve() async {
        do {
            status = try await helper.register()
        } catch {
            status = await helper.status
        }
        guard status != .enabled else { return }
        helper.openApprovalSettings()
        poller?.cancel()
        poller = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.refreshStatus()
                if self.status == .enabled { return }
            }
        }
    }

    func record(_ state: HostsSyncState) {
        lastSync = state
    }
}
