import Foundation
import Observation
import ServiceManagement

/// "Spúšťať pri prihlásení" — `SMAppService.mainApp` (05-06). The system is the source of truth: the status is
/// re-read on every appear, never cached in UserDefaults.
@MainActor @Observable
final class LoginItem {
    enum Status: Equatable {
        case enabled, requiresApproval, notRegistered, notFound
    }

    private(set) var status: Status = .notRegistered
    /// NSError text of the last failed register / unregister.
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = Self.map(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = (error as NSError).localizedDescription
        }
        refresh()
    }

    /// "Otvoriť Nastavenia systému" (status `requiresApproval`).
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }
}
