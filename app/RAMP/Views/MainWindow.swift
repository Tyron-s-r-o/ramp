import SwiftUI
import RAMPCore

struct MainWindow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var terminal = app.terminal
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $app.selection) { section in
                // Fixed icon box: SF Symbols differ in width, so titles would not line up otherwise.
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.systemImage)
                        .frame(width: 20, alignment: .center)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let error = app.lastError {
                    ErrorBanner(error: error) { app.lastError = nil }
                }
                detail
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .toolbar { toolbar }
        .frame(minWidth: 820, minHeight: 520)
        // Terminal integration: MAMP lines prompt + one-time "Terminál nastavený" notice.
        .sheet(isPresented: $terminal.showPrompt) { TerminalPromptSheet() }
        .alert(Text("Terminál nastavený: php, php\(app.terminal.defaultBranch ?? ""), composer, mysql…"),
               isPresented: $terminal.showNotice) {
            Button("Zobraziť v Nastaveniach") { app.selection = .settings }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Otvorte nové okno terminálu (alebo spustite exec $SHELL -l).")
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .services:
            ServicesView()
        case .vhosts:
            VhostsView()
        case .php:
            PHPView()
        case .database:
            DatabaseView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let services = app.services
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await services.startAll() }
            } label: {
                Label("Spustiť všetko", systemImage: "play.fill")
            }
            .disabled(services.isBusyAll)
            .help("Spustiť všetky služby")

            Button {
                Task { await services.stopAll() }
            } label: {
                Label("Zastaviť všetko", systemImage: "stop.fill")
            }
            .disabled(services.isBusyAll)
            .help("Zastaviť všetky služby")

            Button {
                Task { await services.restartApache() }
            } label: {
                Label("Reštart Apache (graceful)", systemImage: "arrow.clockwise")
            }
            .disabled(!(services.rows.first { $0.id == .apache }?.state.isRunning ?? false))
            .help("Reštart Apache (graceful)")
        }
        ToolbarItem(placement: .status) {
            StatusBadge(health: services.health)
        }
    }
}
