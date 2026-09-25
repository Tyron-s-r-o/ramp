import Foundation
import Observation
import RAMPCore

/// Nastavenia › Terminál: `~/.ramp/bin` shims (php, php8.3, composer, mysql…), the PATH block in the shell
/// startup files and MAMP lines that would shadow RAMP. Core work: `CLIIntegration` / `ShellIntegration`.
@MainActor @Observable
final class TerminalModel {
    @ObservationIgnored weak var app: AppModel?

    static let noticeShownKey = "terminal.noticeShown"
    static let promptShownKey = "terminal.promptShown"

    private(set) var status: ShellIntegration.Status?
    /// What a new login shell runs for `php` (`zsh -lic 'command -v php'`); nil = not probed / nothing.
    private(set) var probed: String?
    private(set) var isProbing = false
    private(set) var isWorking = false
    private(set) var commands: [String] = []
    private(set) var composerDate: Date?
    private(set) var lastMessage: String?
    /// MAMP lines sheet (first launch with conflicts / once for existing installs / "Nastaviť" with conflicts).
    var showPrompt = false
    /// One-time "Terminál nastavený" notice.
    var showNotice = false

    private var cli: CLIIntegration? { app.map { CLIIntegration(paths: $0.paths) } }

    var resolvesToRAMP: Bool { cli?.shell.resolvesToRAMP(probed) ?? false }
    var defaultBranch: String? { app.flatMap { CLIShimGenerator.defaultBranch($0.config) } }
    var branches: [String] { app.map { CLIShimGenerator.phpBranches($0.config).reversed() } ?? [] }

    // MARK: Launch

    /// App launch: shims + composer; first install (fresh user) adds the PATH block automatically unless MAMP
    /// lines conflict (then the sheet asks); existing installs see the sheet once.
    func onLaunch(freshInstall: Bool) async {
        guard let app, let cli, CLIIntegration.automaticSyncAllowed() else { return }
        do {
            try cli.syncShims(config: app.config)
        } catch {
            app.report(title: String(localized: "Príkazy terminálu sa nepodarilo pripraviť"), error: error)
        }
        if cli.composer.needsRefresh() {
            Task { [weak self, cli] in
                _ = try? await cli.composer.update()
                await self?.refresh(probe: false)
            }
        }
        let shellStatus = cli.shell.status()
        let defaults = UserDefaults.standard
        if freshInstall {
            if shellStatus.blockingConflicts.isEmpty {
                await install(disableMAMP: false, announce: !defaults.bool(forKey: Self.noticeShownKey))
            } else {
                showPrompt = true
            }
            defaults.set(true, forKey: Self.promptShownKey)
        } else if !defaults.bool(forKey: Self.promptShownKey) {
            if !shellStatus.blockingConflicts.isEmpty || !shellStatus.blockInstalled { showPrompt = true }
            defaults.set(true, forKey: Self.promptShownKey)
        }
        await refresh(probe: false)
    }

    // MARK: Status

    func refresh(probe: Bool = true) async {
        guard let app, let cli else { return }
        status = cli.shell.status()
        commands = cli.commandNames(config: app.config)
        composerDate = cli.composer.installedAt
        #if DEBUG
        if ScreenshotMode.isActive {
            probed = cli.shimDir.appending(path: "php").path(percentEncoded: false)
            commands = DemoData.terminalCommands
            return
        }
        #endif
        guard probe, !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        probed = await cli.shell.probe()
    }

    // MARK: Actions

    /// "Nastaviť": with conflicting MAMP lines the sheet asks first.
    func setUp() async {
        if let status, !status.blockingConflicts.isEmpty {
            showPrompt = true
        } else {
            await install(disableMAMP: false, announce: true)
        }
    }

    func install(disableMAMP: Bool, announce: Bool = true) async {
        guard let app, let cli else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try cli.syncShims(config: app.config)
            let report = try cli.shell.install(disableMAMP: disableMAMP)
            lastMessage = report.disabledMAMP > 0
                ? String(localized: "Nastavené, vypnuté riadky MAMPu: \(report.disabledMAMP)")
                : String(localized: "Nastavené — otvorte nový terminál")
            if announce {
                UserDefaults.standard.set(true, forKey: Self.noticeShownKey)
                showNotice = true
            }
        } catch {
            app.report(title: String(localized: "Terminál sa nepodarilo nastaviť"), error: error)
        }
        if !cli.composer.isInstalled { await updateComposer() }
        await refresh()
    }

    /// "Odstrániť": PATH blocks out, MAMP lines RAMP disabled back in (shims stay, they are harmless off PATH).
    func remove() async {
        guard let app, let cli else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try cli.shell.uninstall(restoreMAMP: true)
            lastMessage = String(localized: "RAMP odstránený z PATH, obnovené riadky MAMPu: \(report.restoredMAMP)")
        } catch {
            app.report(title: String(localized: "Terminál sa nepodarilo upraviť"), error: error)
        }
        await refresh()
    }

    func restoreMAMP() async {
        guard let app, let cli else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try cli.shell.restoreMAMP()
            lastMessage = String(localized: "Obnovené riadky MAMPu: \(report.restoredMAMP)")
        } catch {
            app.report(title: String(localized: "Terminál sa nepodarilo upraviť"), error: error)
        }
        await refresh()
    }

    func updateComposer() async {
        guard let app, let cli else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await cli.composer.update()
            lastMessage = String(localized: "Composer aktualizovaný")
        } catch {
            app.report(title: String(localized: "Composer sa nepodarilo stiahnuť"), error: error)
        }
        composerDate = cli.composer.installedAt
    }

    /// `cli.defaultPHP` (nil = automaticky) → ramp.json → shims.
    func setDefault(_ branch: String?) async {
        guard let app, let cli else { return }
        do {
            let saved = try await app.configStore.update { $0.cli.defaultPHP = branch }
            try cli.syncShims(config: saved)
        } catch {
            app.report(title: String(localized: "Nastavenia sa nepodarilo uložiť"), error: error)
        }
        await app.reloadConfig()
        await refresh(probe: false)
    }
}
