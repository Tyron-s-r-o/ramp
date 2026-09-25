import SwiftUI
import AppKit
import RAMPCore

/// "Import z MAMP PRO" window (07-05): sidebar stepper + one step at a time.
struct ImportWizardView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.mampImport
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.step) }, set: { if let s = $0 { model.step = s } })) {
                stepRow(.vhosts, title: "Vhosty", icon: "globe")
                stepRow(.mysql, title: "Databázy", icon: "cylinder.split.1x2")
                stepRow(.elasticsearch, title: "Elasticsearch", icon: "magnifyingglass")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if !model.mampFound && model.step == .vhosts {
                    ContentUnavailableView("MAMP PRO sa nenašiel",
                                           systemImage: "questionmark.folder",
                                           description: Text("Konfigurácia MAMP PRO (httpd.conf) nie je v ~/Library/Application Support/appsolute/MAMP PRO"))
                } else {
                    switch model.step {
                    case .vhosts: ImportVhostsStep(model: model)
                    case .mysql: ImportDatabaseStep(model: model)
                    case .elasticsearch, .launchAgent: ImportElasticsearchStep(model: model)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .navigationTitle("Import z MAMP PRO")
        .task { await model.open() }
        .onAppear { NSApplication.shared.activate() }
    }

    private func stepRow(_ step: MAMPImportStep, title: LocalizedStringKey, icon: String) -> some View {
        let model = app.mampImport
        let status = step == .elasticsearch ? combinedESStatus(model) : model.status(step)
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                ImportStatusText(status: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: statusIcon(status) ?? icon)
                .foregroundStyle(statusColor(status))
        }
        .tag(step)
    }

    private func combinedESStatus(_ model: ImportModel) -> MAMPImportStepStatus {
        let es = model.status(.elasticsearch)
        let la = model.status(.launchAgent)
        if es == .running || la == .running { return .running }
        if es == .failed || la == .failed { return .failed }
        return es
    }

    private func statusIcon(_ status: MAMPImportStepStatus) -> String? {
        switch status {
        case .done: "checkmark.circle.fill"
        case .skipped: "forward.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .notStarted, .previewed: nil
        }
    }

    private func statusColor(_ status: MAMPImportStepStatus) -> Color {
        switch status {
        case .done: .green
        case .failed: .orange
        case .skipped: .secondary
        default: .accentColor
        }
    }
}

struct ImportStatusText: View {
    let status: MAMPImportStepStatus

    var body: some View {
        switch status {
        case .notStarted: Text("Nezačaté")
        case .previewed: Text("Náhľad")
        case .running: Text("Prebieha…")
        case .done: Text("Hotovo")
        case .skipped: Text("Preskočené")
        case .failed: Text("Zlyhalo")
        }
    }
}

/// Footer shared by the steps: Preskočiť + primary action.
struct ImportStepFooter<Primary: View>: View {
    let model: ImportModel
    let step: MAMPImportStep
    @ViewBuilder var primary: Primary

    var body: some View {
        HStack {
            Button("Preskočiť") { Task { await model.skip(step) } }
                .disabled(model.isRunning)
            Spacer()
            primary
        }
        .padding()
    }
}

/// Settings › Pokročilé and the first-launch offer open the wizard window.
struct MAMPImportButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import z MAMP PRO…") {
            openWindow(id: "mamp-import")
            NSApplication.shared.activate()
        }
    }
}

/// First-launch offer (once per session, "Neukazovať znova" persisted) — attached to the main window.
struct MAMPImportOfferModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        @Bindable var model = app.mampImport
        content
            .task { await model.checkOffer() }
            .alert("Importovať z MAMP PRO?", isPresented: $model.showOffer) {
                Button("Otvoriť import") {
                    openWindow(id: "mamp-import")
                    NSApplication.shared.activate()
                }
                Button("Neskôr", role: .cancel) {}
                Button("Neukazovať znova") { model.dismissOfferForever() }
            } message: {
                Text("RAMP našiel konfiguráciu MAMP PRO. Sprievodca prevezme vhosty, databázy a dáta Elasticsearch — každý krok najprv ukáže náhľad a dá sa preskočiť.")
            }
    }
}

extension View {
    func mampImportOffer() -> some View { modifier(MAMPImportOfferModifier()) }
}

enum ImportFormat {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "–"
    }
}
