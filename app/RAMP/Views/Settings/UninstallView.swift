import SwiftUI
import RAMPCore

/// "Odinštalovať RAMP…" window (07-07): plan preview → typed confirmation → progress → report → quit.
struct UninstallView: View {
    @Environment(AppModel.self) private var app
    @State private var model = UninstallModel()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Odinštalovať RAMP")
                .font(.title2.bold())
            if model.isFakeHome {
                Text("DEBUG: falošný domovský priečinok (RAMP_UNINSTALL_FAKE_HOME) — systémové položky sa nemenia.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch model.phase {
            case .idle, .planning:
                ProgressView("Pripravujem plán…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .running:
                optionsSection
                stepsList
                if model.phase == .ready { confirmSection }
            case .finished:
                stepsList
                reportSection
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 560)
        .task {
            model.app = app
            await model.preparePlan()
        }
    }

    // MARK: Sections

    @ViewBuilder private var optionsSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Zálohovať databázy (mysqldump) na Plochu", isOn: $model.dumpDatabases)
                .disabled(!model.mysqlAvailable || model.phase != .ready)
            Toggle("Odstrániť záznamy z /etc/hosts", isOn: $model.removeHostsBlock)
                .disabled(model.phase != .ready)
            Text("Projektové priečinky sa nikdy nemažú")
                .bold()
            if let kept = model.plan?.keptDocroots, !kept.isEmpty {
                ForEach(kept, id: \.self) { path in
                    Label(path, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stepsList: some View {
        List(model.plan?.steps ?? []) { step in
            HStack(alignment: .firstTextBaseline) {
                statusIcon(model.statuses[step.id])
                    .frame(width: 18)
                Text(Self.title(for: step.kind))
                    .textSelection(.enabled)
                Spacer()
                if case .delete(_, let bytes) = step.kind, bytes > 0 {
                    Text(UninstallPlanner.formatBytes(bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help(step.description)
        }
        .frame(minHeight: 220)
    }

    @ViewBuilder private var confirmSection: some View {
        @Bindable var model = model
        if let plan = model.plan {
            Text("Spolu sa zmaže: \(UninstallPlanner.formatBytes(plan.totalBytes))")
            if !plan.refusals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Odinštalovanie je zablokované — tieto cesty RAMP nesmie zmazať:")
                        .bold()
                        .foregroundStyle(.red)
                    ForEach(plan.refusals, id: \.self) { Text(verbatim: $0).font(.caption) }
                }
            } else {
                Text("Pre potvrdenie napíšte \(UninstallModel.confirmationWord)")
                HStack {
                    TextField(UninstallModel.confirmationWord, text: $model.confirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Spacer()
                    Button("Odinštalovať", role: .destructive) { Task { await model.run() } }
                        .disabled(!model.canConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder private var reportSection: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 8) {
                if let aborted = report.aborted {
                    Text("Odinštalovanie bolo prerušené, nič sa nezmazalo.")
                        .bold()
                        .foregroundStyle(.red)
                    Text(verbatim: aborted).font(.caption).textSelection(.enabled)
                } else {
                    if report.warnings.isEmpty {
                        Text("RAMP bol odinštalovaný.").bold()
                    } else {
                        Text("RAMP bol odinštalovaný s upozorneniami.").bold()
                    }
                }
                if let dump = report.dumpFile {
                    HStack {
                        Text("Záloha databáz: \(dump.path(percentEncoded: false))")
                            .textSelection(.enabled)
                        Button("Zobraziť vo Finderi") { model.revealDump() }
                    }
                }
                if !report.manualSteps.isEmpty {
                    Text("Dokončite ručne:")
                        .bold()
                    ForEach(report.manualSteps, id: \.self) {
                        Text(verbatim: $0).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                ForEach(report.warnings, id: \.self) {
                    Text(verbatim: $0).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    if report.aborted == nil {
                        Button("Ukončiť") { model.quit() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Zavrieť") { NSApp.keyWindow?.close() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder private func statusIcon(_ status: UninstallStepStatus?) -> some View {
        switch status {
        case nil: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    static func title(for kind: UninstallStepKind) -> String {
        switch kind {
        case .acquireLock:
            String(localized: "Zablokovať ostatné údržbové úlohy")
        case .stopServices:
            String(localized: "Zastaviť všetky služby")
        case .dumpDatabases(let url):
            String(localized: "Zálohovať databázy do \(url.path(percentEncoded: false))")
        case .removeHostsBlock:
            String(localized: "Odstrániť záznamy RAMP z /etc/hosts")
        case .unregisterHelper:
            String(localized: "Odregistrovať hosts helper")
        case .unregisterLoginItem:
            String(localized: "Odstrániť RAMP z položiek pri prihlásení")
        case .delete(let url, _):
            String(localized: "Zmazať \(url.path(percentEncoded: false))")
        case .removePreferencesDomain(let id):
            String(localized: "Odstrániť nastavenia \(id)")
        case .trashApp(let url):
            String(localized: "Presunúť \(url.lastPathComponent) do koša")
        case .removeShellIntegration:
            String(localized: "Odstrániť RAMP z PATH v termináli a obnoviť vypnuté riadky MAMPu")
        }
    }
}
