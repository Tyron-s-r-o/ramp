import SwiftUI
import AppKit
import RAMPCore

/// Step 3 — Elasticsearch data (detected source + precheck + migrate) and the legacy auto-stop LaunchAgent (removed
/// only after the confirmation checkbox is ticked).
struct ImportElasticsearchStep: View {
    @Bindable var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Elasticsearch").font(.title2.bold())
                    sourcePicker
                    if let p = model.esPrecheck { precheck(p) }
                    if model.esRunning || model.esResult != nil || model.esError != nil { progress }
                    if !model.agents.isEmpty || model.agentResult != nil { launchAgentSection }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ImportStepFooter(model: model, step: .elasticsearch) {
                if model.esRunning {
                    ProgressView().controlSize(.small)
                    Button("Zrušiť") { model.cancelES() }
                } else {
                    Button("Migrovať dáta") { Task { await model.runES() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isRunning || !(model.esPrecheck?.ok ?? false) || model.esResult != nil)
                }
            }
        }
        .task {
            await model.ensureCoordinator()
            model.detectES()
        }
    }

    private var sourcePicker: some View {
        HStack {
            if model.esSources.isEmpty {
                Text("V ~/Lib sa nenašla inštalácia Elasticsearch").foregroundStyle(.secondary)
            } else {
                Picker("Zdroj", selection: $model.esSource) {
                    ForEach(model.esSources, id: \.self) { s in
                        Text(verbatim: "\(s.root.path(percentEncoded: false)) (\(s.version ?? "?"))")
                            .tag(Optional(s))
                    }
                }
            }
            Button("Vybrať priečinok…") { model.chooseESFolder() }
            Button("Znova skontrolovať") { model.refreshES() }
                .disabled(model.esSource == nil || model.esRunning)
        }
    }

    private func precheck(_ p: ElasticsearchMigrationPrecheck) -> some View {
        GroupBox("Kontrola") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Verzia") {
                    Text(verbatim: "\(p.source.version ?? "?") → RAMP \(p.targetBranch)")
                }
                LabeledContent("Dáta") {
                    Text(verbatim: "\(ImportFormat.bytes(p.bytes)) · \(p.files)")
                }
                LabeledContent("Cieľ") {
                    Text(verbatim: p.target.path(percentEncoded: false)).textSelection(.enabled)
                }
                LabeledContent("APFS klon") { Text(p.clonePossible ? LocalizedStringKey("áno") : LocalizedStringKey("nie")) }
                LabeledContent("Voľné miesto") { Text(verbatim: p.freeBytes.map(ImportFormat.bytes) ?? "?") }
                if model.esInstalledInRAMP {
                    Toggle("Po migrácii overiť (spustí a zastaví RAMP Elasticsearch)", isOn: $model.esSmoke)
                        .disabled(model.esRunning)
                }
                ForEach(p.problems, id: \.self) { problem in
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "xmark.octagon.fill") }
                        .foregroundStyle(.red)
                }
                ForEach(p.warnings, id: \.self) { w in
                    Label { Text(verbatim: w) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Text("Zdrojový priečinok sa nikdy nemení ani nemaže.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progress: some View {
        GroupBox("Priebeh") {
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.esProgress, model.esRunning {
                    ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    Text(verbatim: "\(ImportFormat.bytes(p.bytesDone)) / \(ImportFormat.bytes(p.bytesTotal)) · \(p.filesDone)/\(p.filesTotal)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if model.esRunning {
                    ProgressView().controlSize(.small)
                }
                if let r = model.esResult {
                    Label("Dáta presunuté do RAMP", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(verbatim: r.target.path(percentEncoded: false)).font(.callout.monospaced()).textSelection(.enabled)
                    if let aside = r.movedAside {
                        LabeledContent("Pôvodné dáta RAMP") {
                            Text(verbatim: aside.lastPathComponent).font(.callout.monospaced())
                        }
                    }
                    if let indices = r.smokeIndices, !indices.isEmpty {
                        Text(verbatim: indices.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
                            .font(.callout)
                    }
                    ForEach(r.warnings, id: \.self) { w in
                        Text(verbatim: w).font(.callout).foregroundStyle(.orange)
                    }
                }
                if let e = model.esError {
                    Label { Text(verbatim: e).textSelection(.enabled) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var launchAgentSection: some View {
        GroupBox("Zrušiť starý auto-stop LaunchAgent") {
            VStack(alignment: .leading, spacing: 8) {
                Text("RAMP má vlastný auto-stop Elasticsearch — starý LaunchAgent už netreba.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(model.agents, id: \.self) { agent in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Label") { Text(verbatim: agent.label).font(.callout.monospaced()) }
                        if let source = model.esSource {
                            LabeledContent("Skript") {
                                Text(verbatim: agent.scriptPath(in: source.root) ?? "?").font(.callout.monospaced())
                            }
                        }
                        LabeledContent("Plist") {
                            Text(verbatim: agent.plistURL.path(percentEncoded: false)).font(.callout.monospaced())
                        }
                        Toggle("Rozumiem, RAMP ho odstráni (plist pôjde do Koša)", isOn: $model.agentConfirmed)
                            .disabled(model.agentBusy)
                        HStack {
                            Spacer()
                            if model.agentBusy { ProgressView().controlSize(.small) }
                            Button("Odstrániť LaunchAgent", role: .destructive) {
                                Task { await model.removeAgent(agent) }
                            }
                            .disabled(!model.agentConfirmed || model.isRunning)
                        }
                    }
                }
                if let trashed = model.agentResult {
                    Label { Text("LaunchAgent odstránený, plist je v Koši") } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                    Text(verbatim: trashed).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let e = model.agentError {
                    Text(verbatim: e).font(.callout).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
