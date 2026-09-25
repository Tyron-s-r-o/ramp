import AppKit

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
        if ScreenshotMode.isActive, let model = Self.appModel { ScreenshotMode.start(model); return }
        #endif
        AppUpdater.shared.start()   // 08-03 Sparkle (no-op in DEBUG / unconfigured builds)
        guard let model = Self.appModel else { return }
        Task { await model.launch() }
        Task { await HelperUpgradeCheck.run(model.hostsHelper.helper) }   // 08-03 helper after app update
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
