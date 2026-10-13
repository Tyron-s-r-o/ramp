import AppKit
import RAMPCore

/// Starts the stack on launch and stops it before the app quits (services must not outlive RAMP).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `RAMPApp.init` (runs before `applicationDidFinishLaunching`).
    static var appModel: AppModel?
    private var terminating = false

    /// Dock icon preference (05-06) before any window appears.
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockPolicy.applyStored()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Marketing screenshots: demo data only — no Sparkle, stack launch, helper or hosts sync.
        if ScreenshotMode.isActive {
            // -RAMPSandbox: stay open without the stack for manual testing (FTP works for real).
            if ScreenshotMode.isRendering, let model = Self.appModel { ScreenshotMode.start(model) }
            else { ScreenshotMode.startSandbox() }
            return
        }
        #endif
        guard let model = Self.appModel else { return }
        // One supervisor per RAMP home: a second copy (e.g. a Debug build next to /Applications/RAMP.app) would
        // start PHP-FPM & co. again and collide on sockets/ports — tell the user, bring up the other copy, quit.
        guard let lock = InstanceLock.acquire(paths: model.paths) else {
            Self.quitAsDuplicate(owner: InstanceLock.holderPID(paths: model.paths))
            return
        }
        Self.instanceLock = lock
        AppUpdater.shared.start()   // 08-03 Sparkle (no-op in DEBUG / unconfigured builds)
        Task { await model.launch() }
        Task { await HelperUpgradeCheck.run(model.hostsHelper.helper) }   // 08-03 helper after app update
    }

    /// Held for the whole process lifetime (released by the kernel when RAMP exits).
    private static var instanceLock: InstanceLock?

    private static func quitAsDuplicate(owner: pid_t?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "RAMP už beží")
        alert.informativeText = owner.map { pid in String(localized: "Služby už spravuje iná spustená kópia RAMP (PID \(String(pid))). Táto kópia sa ukončí, aby nespúšťala služby druhýkrát.") }   // String: no "87 797" grouping
            ?? String(localized: "Služby už spravuje iná spustená kópia RAMP. Táto kópia sa ukončí, aby nespúšťala služby druhýkrát.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApplication.shared.activate()
        alert.runModal()
        if let owner { NSRunningApplication(processIdentifier: owner)?.activate() }
        // exit, not terminate: applicationShouldTerminate would stop the stack — which belongs to the other copy.
        exit(0)
    }

    /// The menu bar keeps RAMP alive without windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.appModel else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        // 07-05: MAMP import running → confirm, then cancel it (state persisted, the wizard resumes next launch).
        if model.mampImport.isRunning {
            let alert = NSAlert()
            alert.messageText = String(localized: "Import z MAMP PRO práve beží")
            alert.informativeText = String(localized: "Ukončenie ho preruší. Stav sa uloží a import môžeš dokončiť po ďalšom spustení.")
            alert.addButton(withTitle: String(localized: "Prerušiť a ukončiť"))
            alert.addButton(withTitle: String(localized: "Pokračovať v importe"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            model.mampImport.cancelAll()
        }
        terminating = true
        model.updates.stop()
        model.elasticsearch.stopScheduler()   // 06-04: ES itself is stopped by stopAll below
        Task { @MainActor in
            // stopAll, capped at 45 s (≥ Elasticsearch stopTimeout 30 s + margin, 06-03; ES has no dependencies so
            // the supervisor stops it concurrently with the rest) — then quit regardless (SIGKILL after timeouts).
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.services.stopAll() }
                group.addTask { try? await Task.sleep(for: .seconds(45)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
