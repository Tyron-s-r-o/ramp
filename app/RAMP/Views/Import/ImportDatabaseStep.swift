import SwiftUI
import RAMPCore

/// Step 2 — MySQL (07-04 engine): method choice, precheck panel with blockers, MAMP root password, live progress
/// (phases, copy rate/ETA, upgrade elapsed + last log line), cancel / resume / discard, final report.
struct ImportDatabaseStep: View {
    @Bindable var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Databázy").font(.title2.bold())
                    methodPicker
                    precheckPanel
                    if !model.mysqlRunning && !(model.mysqlState?.isComplete ?? false) {
                        LabeledContent("MAMP root heslo") {
                            SecureField(text: $model.rootPassword, prompt: Text(verbatim: "root")) { EmptyView() }
                                .frame(maxWidth: 200)
                        }
                    }
                    if model.mysqlRunning || model.mysqlState != nil { progressPanel }
                    if let error = model.mysqlError {
                        Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if let state = model.mysqlState, state.isComplete { report(state) }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ImportStepFooter(model: model, step: .mysql) {
                footerButtons
            }
        }
        .task {
            await model.ensureCoordinator()
            if model.mysqlPrecheck == nil { await model.precheckMySQL() }
        }
    }

    private var methodPicker: some View {
        Picker("Metóda", selection: $model.method) {
            VStack(alignment: .leading) {
                Text("Kópia datadiru + upgrade — odporúčané")
                Text("Klon súborov MySQL 8.0 (bez binlogov) → upgrade 8.4 → 9.7. MAMP MySQL musí byť zastavený.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .tag(MigrationMethod.datadirUpgrade)
            VStack(alignment: .leading) {
                Text("Dump po databázach")
                Text("mysqldump každej databázy do RAMP MySQL. MAMP MySQL musí bežať.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .tag(MigrationMethod.logical)
        }
        .pickerStyle(.radioGroup)
        .disabled(model.mysqlRunning)
    }

    @ViewBuilder private var precheckPanel: some View {
        GroupBox {
            if let p = model.mysqlPrecheck {
                VStack(alignment: .leading, spacing: 4) {
                    if model.mysqlBlockedByMAMP {
                        Label {
                            if model.method == .datadirUpgrade {
                                Text("MAMP MySQL beží — zastav ho v MAMP PRO (Stop) a klikni Znova skontrolovať")
                            } else {
                                Text("MAMP MySQL nebeží — spusti ho v MAMP PRO (Start) a klikni Znova skontrolovať")
                            }
                        } icon: { Image(systemName: "xmark.octagon.fill") }
                        .foregroundStyle(.red)
                        .font(.headline)
                    }
                    row("Zdroj", p.source.path(percentEncoded: false))
                    row("Veľkosť zdroja", ImportFormat.bytes(p.sizes.totalBytes))
                    row("Binlogy (vynechané)", ImportFormat.bytes(p.sizes.binlogBytes))
                    row("Na kopírovanie", ImportFormat.bytes(p.sizes.toCopyBytes))
                    row("Voľné miesto", p.freeBytes.map(ImportFormat.bytes) ?? "?")
                    LabeledContent("APFS klon") { Text(p.clonePossible ? LocalizedStringKey("áno") : LocalizedStringKey("nie")) }
                    ForEach(p.packages.filter { $0.installed == nil }, id: \.branch) { pkg in
                        row("MySQL \(pkg.branch) – stiahnutie", pkg.downloadSize.map(ImportFormat.bytes) ?? "?")
                    }
                    row("Schémy", "\(p.schemas.count)")
                    ForEach(p.problems.filter { !model.mysqlBlockedByMAMP || !$0.localizedCaseInsensitiveContains("running") },
                            id: \.self) { problem in
                        Label { Text(verbatim: problem) } icon: { Image(systemName: "xmark.octagon.fill") }
                            .foregroundStyle(.red)
                    }
                    ForEach(p.warnings, id: \.self) { w in
                        Label { Text(verbatim: w) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } label: {
            HStack {
                Text("Kontrola")
                Spacer()
                if model.mysqlChecking { ProgressView().controlSize(.small) }
                Button("Znova skontrolovať") { Task { await model.precheckMySQL() } }
                    .disabled(model.mysqlChecking || model.mysqlRunning)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) { Text(verbatim: value).textSelection(.enabled) }
    }

    private var progressPanel: some View {
        GroupBox("Priebeh") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.mysqlSteps, id: \.self) { step in
                    HStack {
                        if model.isDone(step) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if model.mysqlCurrentStep == step && model.mysqlRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                        Text(stepTitle(step))
                    }
                }
                if model.mysqlRunning, model.mysqlCurrentStep == .copy, let c = model.mysqlCopy {
                    ProgressView(value: Double(c.bytesDone), total: Double(max(c.bytesTotal, 1)))
                    HStack {
                        Text(verbatim: "\(ImportFormat.bytes(c.bytesDone)) / \(ImportFormat.bytes(c.bytesTotal)) · \(c.filesDone)/\(c.filesTotal)")
                        if let r = model.copyRate {
                            Text(verbatim: "· \(ImportFormat.bytes(Int64(r.rate)))/s")
                            if let eta = r.eta { Text("· zostáva \(ImportFormat.duration(eta))") }
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if model.mysqlRunning, let s = model.mysqlServerLine,
                   [.upgrade84, .upgrade97, .convertUsers, .verify].contains(model.mysqlCurrentStep) {
                    Text("MySQL \(s.branch): \(ImportFormat.duration(TimeInterval(s.elapsed)))")
                        .font(.callout.monospacedDigit())
                    if let line = s.line {
                        Text(verbatim: line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if model.mysqlRunning, model.method == .logical, let d = model.mysqlDatabase {
                    Text(verbatim: "\(d.index)/\(d.total) · \(d.name)").font(.callout.monospaced())
                }
                if let failure = model.mysqlState?.failure, !model.mysqlRunning {
                    Text(verbatim: "\(failure.step): \(failure.message)").font(.callout).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepTitle(_ step: MigrationStep) -> LocalizedStringKey {
        switch step {
        case .copy: "Kópia datadiru"
        case .upgrade84: "Upgrade na MySQL 8.4"
        case .convertUsers: "Prevod účtov"
        case .upgrade97: "Upgrade na MySQL 9.7"
        case .verify: "Overenie"
        case .activate: "Aktivácia v RAMP"
        case .importDatabases: "Import databáz"
        }
    }

    private func report(_ state: MigrationState) -> some View {
        GroupBox("Výsledok") {
            VStack(alignment: .leading, spacing: 4) {
                Label("Migrácia dokončená", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                row("Schémy", "\(state.schemas.count)")
                let tables = (state.tableCountsFinal.isEmpty ? state.tableCounts84 : state.tableCountsFinal).values.reduce(0, +)
                row("Tabuľky", "\(tables)")
                if !state.unconvertedAccounts.isEmpty {
                    Text("Neprevedené účty (mysql_native_password, v MySQL 9.7 sa neprihlásia):")
                        .font(.callout)
                    ForEach(state.unconvertedAccounts.map { "\($0)" }, id: \.self) { a in
                        Text(verbatim: "• \(a)").font(.callout.monospaced())
                    }
                    Text("Zmeň im heslo cez phpMyAdmin (ALTER USER … IDENTIFIED WITH caching_sha2_password).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        if model.mysqlRunning {
            ProgressView().controlSize(.small)
            Button("Zrušiť") { model.cancelMySQL() }
        } else if model.mysqlState?.isComplete ?? false {
            Button("Ďalej") { model.advance(from: .mysql) }
                .keyboardShortcut(.defaultAction)
        } else {
            if model.mysqlState != nil {
                Button("Zahodiť kópiu", role: .destructive) { Task { await model.discardMySQL() } }
                    .disabled(model.isRunning)
            }
            Button(model.canResumeMySQL ? LocalizedStringKey("Pokračovať") : LocalizedStringKey("Spustiť")) { Task { await model.runMySQL() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || !(model.mysqlPrecheck?.ok ?? false))
        }
    }
}
