import SwiftUI
import AppKit
import RAMPCore

@main
struct RAMPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        ScreenshotMode.prepare()   // DEBUG `-RAMPScreenshots <dir>`: sandbox + demo data (no-op otherwise)
        // Older builds could autosave a split-view height far larger than the window (content off-screen).
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView")
        let model = AppModel()
        _appModel = State(initialValue: model)
        // App.init runs before NSApplication finishes launching → the delegate's launch/quit hooks use this instance.
        AppDelegate.appModel = model
    }

    var body: some Scene {
        Window("RAMP", id: "main") {
            MainWindow()
                .mampImportOffer()   // 07-05: first-launch offer
                .environment(appModel)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()   // 08-03 Sparkle
                UninstallMenuButton()   // 07-07
            }
        }

        // Uninstall (07-07): plan preview, typed confirmation, progress, report.
        // MAMP PRO import wizard (07-05): Nastavenia › Pokročilé + first-launch offer.
        // Redis browser in its own window (Databáza › Redis › "Prehliadať databázu").
        Window("Redis", id: "redis-browser") {
            RedisBrowserWindow()
                .environment(appModel)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Window("Import z MAMP PRO", id: "mamp-import") {
            ImportWizardView()
                .environment(appModel)
        }
        .windowResizability(.contentMinSize)

        Window("Odinštalovať RAMP", id: "uninstall") {
            UninstallView()
                .environment(appModel)
        }
        .windowResizability(.contentMinSize)

        // ⌘, (05-06): same SettingsView as the Nastavenia sidebar section.
        Settings {
            SettingsView(isSettingsScene: true)
                .frame(minWidth: 600, idealWidth: 660, minHeight: 520, idealHeight: 720)
                .environment(appModel)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appModel)
        } label: {
            MenuBarLabel()
                .environment(appModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// "Odinštalovať RAMP…" — app menu and menu bar (07-07).
struct UninstallMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Odinštalovať RAMP…") {
            openWindow(id: "uninstall")
            NSApplication.shared.activate()
        }
    }
}
