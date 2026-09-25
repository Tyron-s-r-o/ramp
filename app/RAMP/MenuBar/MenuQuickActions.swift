import AppKit
import SwiftUI
import RAMPCore

/// Rýchle akcie: OPcache / Xdebug per branch (via PHPModel → PHPManager), phpMyAdmin, logs.
struct MenuQuickActions: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let php = app.php
        let running = runningFPMBranches
        let branches = php.branches.filter(\.enabled)
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionTitle("Rýchle akcie")
            HStack(spacing: 6) {
                Menu("Vyčistiť OPcache") {
                    ForEach(running, id: \.self) { b in
                        Button("PHP \(b)") { php.clearOPcache(b) }
                    }
                    if running.count > 1 {
                        Divider()
                        Button("Všetky") { running.forEach { php.clearOPcache($0) } }
                    }
                }
                .disabled(running.isEmpty)

                Menu("Xdebug") {
                    ForEach(branches) { info in
                        Picker(selection: Binding(get: { info.settings.xdebug },
                                                  set: { php.setXdebug(info.branch, $0) })) {
                            Text("Vypnutý").tag(XdebugMode.off)
                            Text(verbatim: "Debug").tag(XdebugMode.debug)
                            Text(verbatim: "Profile").tag(XdebugMode.profile)
                        } label: {
                            Text(verbatim: "PHP \(info.branch) — \(Self.modeName(info.settings.xdebug))")
                        }
                        .pickerStyle(.menu)
                        .disabled(php.isBusy(info.branch))
                    }
                }
                .disabled(branches.isEmpty)
            }
            .fixedSize()
            HStack(spacing: 6) {
                Button("phpMyAdmin") {
                    NSWorkspace.shared.open(app.localhostURL.appending(path: "phpmyadmin/"))
                }
                Button("Logy") {
                    MainWindowOpener(app: app, openWindow: openWindow, dismiss: dismiss)(.logs)
                }
                Button("Otvoriť priečinok logov") { NSWorkspace.shared.open(app.paths.logs) }
            }
            if let status = php.status {
                Text(verbatim: status).font(.caption).foregroundStyle(.green)
            }
        }
        .controlSize(.small)
    }

    private var runningFPMBranches: [String] {
        app.services.rows.compactMap { row -> (String, PHPBranch)? in
            guard case .phpFPM(let b) = row.id, row.state.isRunning, let v = PHPBranch(b) else { return nil }
            return (b, v)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    static func modeName(_ mode: XdebugMode) -> String {
        switch mode {
        case .off: String(localized: "Vypnutý")
        case .debug: "Debug"
        case .profile: "Profile"
        }
    }
}
