import AppKit
import SwiftUI
import RAMPCore

/// `MenuBarExtra(.window)` popover (plan/09). Everything comes from models already in memory — no disk or
/// network work in the bodies, so the popover opens instantly.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MenuHeader()
                Divider()
                MenuServicesSection()
                Divider()
                MenuQuickActions()
                Divider()
                MenuVhostList()
                Divider()
                MenuFooter()
                CheckForUpdatesMenuItem()   // 08-03 (release builds only)
            }
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Opens the main window on a section (used by the header, quick actions and footer).
@MainActor
struct MainWindowOpener {
    let app: AppModel
    let openWindow: OpenWindowAction
    let dismiss: DismissAction

    func callAsFunction(_ section: SidebarSection? = nil) {
        if let section { app.selection = section }
        openWindow(id: "main")
        NSApplication.shared.activate()
        dismiss()
    }
}

struct MenuSectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

/// "RAMP" + health, update row, hosts helper / last error rows.
private struct MenuHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let open = MainWindowOpener(app: app, openWindow: openWindow, dismiss: dismiss)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "RAMP").font(.headline)
                Spacer()
                StatusBadge(health: app.services.health)
            }
            let count = app.updates.updates.count
            if count > 0 {
                Button {
                    open(.settings)
                } label: {
                    Label("Dostupné aktualizácie (\(count))", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            MenuUpdateNotes { open(.settings) }   // 07-02
            if app.config.hosts.manageHostsFile, app.hostsHelper.status != .enabled {
                Button {
                    Task { await app.hostsHelper.approve() }
                } label: {
                    Label("Povoliť hosts helper…", systemImage: "lock.shield")
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "Hosts helper: \(app.hostsHelper.statusText)"))
            }
            if case .pending(let reason) = app.hostsHelper.lastSync {
                Button {
                    Task { await app.syncHosts() }
                } label: {
                    Label("Zopakovať zápis do /etc/hosts", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: reason))
            }
            if let error = app.lastError {
                Text(verbatim: "⚠︎ \(error.title)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(Text(verbatim: "\(error.title)\n\(error.message)"))
            }
        }
    }
}

/// "Otvoriť RAMP" / "Ukončiť RAMP (zastaví služby)".
private struct MenuFooter: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("Otvoriť RAMP") {
                MainWindowOpener(app: app, openWindow: openWindow, dismiss: dismiss)()
            }
            Spacer()
            // Terminate → AppDelegate.applicationShouldTerminate stops every service first.
            Button("Ukončiť RAMP (zastaví služby)") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }
}
