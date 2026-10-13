import Foundation
import RAMPHostsKit
import Security
import ServiceManagement

/// Hosts sync through the privileged LaunchDaemon embedded in RAMP.app (`sk.tyron.ramp.hostshelper`),
/// registered with `SMAppService.daemon`. The XPC peer is pinned to the helper's signing identifier and
/// RAMP's own Team ID; without a team signature (rampctl, ad-hoc builds) this path is unavailable.
public actor HelperHostsSync: PrivilegedHostsSyncing {
    public static let helperIdentifier = "sk.tyron.ramp.hostshelper"

    private let timeout: Duration
    private var versionChecked = false
    /// One repair attempt per app run (see `repairRegistration`).
    private var repairTried = false

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    private nonisolated var service: SMAppService { SMAppService.daemon(plistName: RAMPHostsHelper.plistName) }

    public var status: HelperStatus {
        Self.map(service.status)
    }

    static func map(_ status: SMAppService.Status) -> HelperStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Registers the daemon. The first registration normally needs the user's approval in System Settings —
    /// that is reported as `.requiresApproval`, not as an error.
    @discardableResult
    public func register() throws -> HelperStatus {
        do {
            try service.register()
        } catch let error as NSError {
            let current = status
            if current == .requiresApproval || current == .enabled
                || (error.domain == "SMAppServiceErrorDomain" && error.code == 1) {
                return current == .enabled ? .enabled : .requiresApproval
            }
            throw error
        }
        return status
    }

    /// System Settings › General › Login Items & Extensions.
    public nonisolated func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// After an app update (Sparkle replaces RAMP.app) launchd can keep a stale launch constraint for the
    /// daemon: every spawn fails with EX_CONFIG and XPC calls just time out, while `SMAppService` still says
    /// `.enabled`. Unregister + register makes launchd re-read the bundled helper. Tried once per app run;
    /// `true` when the daemon is enabled again (no new approval is needed for an already approved team).
    private func repairRegistration() async -> Bool {
        guard !repairTried else { return false }
        repairTried = true
        try? await service.unregister()
        try? await Task.sleep(for: .milliseconds(500))
        return (try? register()) == .enabled
    }

    /// The helper did not answer or the connection broke — as opposed to an error reported BY the helper.
    private static func isUnreachable(_ error: any Error) -> Bool {
        switch error as? HostsSyncError {
        case .timeout, .helperFailed: true
        default: false
        }
    }

    public func apply(names: [String]) async throws -> HostsSyncOutcome {
        do {
            return try await applyOnce(names: names)
        } catch where Self.isUnreachable(error) {
            guard await repairRegistration() else { throw error }
            versionChecked = false
            return try await applyOnce(names: names)
        }
    }

    private func applyOnce(names: [String]) async throws -> HostsSyncOutcome {
        guard let team = Self.ownTeamID() else {
            throw HostsSyncError.helperUnavailable("RAMP is not signed with a Team ID")
        }
        let requirement = try RAMPHostsHelper.codeSigningRequirement(identifier: Self.helperIdentifier, teamID: team)
        if !versionChecked {
            let version = try await call(requirement) { proxy, shot in
                proxy.version { shot.resume(.success($0)) }
            }
            versionChecked = true
            if version != RAMPHostsHelper.version {
                // A different helper build is registered (app updated) — re-register so launchd picks up ours.
                _ = try? register()
            }
        }
        let failure: String? = try await call(requirement) { proxy, shot in
            proxy.setHostsBlock(names) { shot.resume(.success($0)) }
        }
        if let failure { throw HostsSyncError.helperFailed(failure) }
        return .updated(via: .helper)
    }

    /// Launch-time check (08-03): after an app update the registered daemon may be an older helper build.
    /// Only when the daemon is enabled and RAMP is team-signed: asks the helper for its version and re-registers
    /// on a mismatch. `nil` = not applicable / helper unreachable (never prompts, never throws).
    public func verifyRegisteredVersion() async -> (running: String, bundled: String, reregistered: Bool)? {
        guard status == .enabled, let team = Self.ownTeamID(),
              let requirement = try? RAMPHostsHelper.codeSigningRequirement(identifier: Self.helperIdentifier,
                                                                           teamID: team)
        else { return nil }
        guard let running: String = try? await call(requirement, { proxy, shot in
            proxy.version { shot.resume(.success($0)) }
        }) else {
            // Enabled but unreachable → stale registration after an update: repair it now, not at the first vhost save.
            guard await repairRegistration() else { return nil }
            return ("unreachable", RAMPHostsHelper.version, true)
        }
        versionChecked = true
        guard running != RAMPHostsHelper.version else {
            return (running, RAMPHostsHelper.version, false)
        }
        _ = try? register()
        return (running, RAMPHostsHelper.version, true)
    }

    /// One XPC round trip on a fresh connection (launch-on-demand daemon exits when idle).
    private func call<T: Sendable>(_ requirement: String,
                                   _ body: @escaping @Sendable (any RAMPHostsHelperProtocol, OneShot<T>) -> Void)
        async throws -> T {
        let connection = NSXPCConnection(machServiceName: RAMPHostsHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: RAMPHostsHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        let box = UncheckedConnection(connection)
        return try await withReplyTimeout(timeout) { shot in
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { error in
                shot.resume(.failure(HostsSyncError.helperFailed(error.localizedDescription)))
            }
            guard let helper = proxy as? any RAMPHostsHelperProtocol else {
                shot.resume(.failure(HostsSyncError.helperFailed("unexpected XPC proxy")))
                return
            }
            body(helper, shot)
        }
    }

    /// Team ID of the running process, nil when unsigned / ad-hoc.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }
}

/// NSXPCConnection is thread-safe but not marked Sendable.
private struct UncheckedConnection: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
