import SwiftUI
import RAMPCore

/// Step 1 — MAMP vhosts: candidates with include checkbox, PHP branch, HTTPS-only badge, issues; skipped hosts;
/// "Importovať vybrané (N)" → one batch (VhostService.addMany).
struct ImportVhostsStep: View {
    @Bindable var model: ImportModel
    @State private var showSkipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.vhostsResult == nil, !model.phpNeeds.isEmpty {
                phpNeedsBanner
                Divider()
            }
            if let error = model.vhostsError {
                Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding()
            }
            if let result = model.vhostsResult {
                resultView(result)
            } else if model.plan != nil {
                table
                skippedSection
            } else if model.vhostsError == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ImportStepFooter(model: model, step: .vhosts) {
                if model.vhostsResult != nil {
                    Button("Ďalej") { model.advance(from: .vhosts) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    if model.vhostsBusy { ProgressView().controlSize(.small) }
                    Button("Importovať vybrané (\(model.selectedCount))") { Task { await model.importVhosts() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedCount == 0 || model.isRunning)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vhosty").font(.title2.bold())
            if let s = model.plan?.summary {
                Text("\(s.candidates) kandidátov · \(s.sslOnly) len HTTPS · \(s.skipped) preskočených · \(s.warnings) upozornení · \(s.errors) chýb")
                    .foregroundStyle(.secondary)
            }
            Text("Nič sa nezapíše, kým neklikneš Importovať. MAMP PRO konfigurácia sa len číta.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    /// MAMP vhosts on a PHP branch RAMP has not installed (EOL branches are not in the default set).
    @ViewBuilder private var phpNeedsBanner: some View {
        let php = model.app?.php
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.phpNeeds) { need in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PHP \(need.branch) nie je nainštalované — MAMP vhosty, ktoré ho používajú: \(need.domains.count)")
                        Text(verbatim: need.domains.prefix(5).joined(separator: ", ") + (need.domains.count > 5 ? ", …" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let error = php?.installErrors[need.branch] {
                            Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let progress = php?.installing[need.branch] {
                        PackageProgressView(stage: progress.stage, download: progress.download)
                            .frame(width: 220)
                    } else {
                        Button("Nainštalovať PHP \(need.branch)") { Task { await model.installPHP(need.branch) } }
                            .disabled(model.isRunning)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.06))
    }

    private var table: some View {
        Table($model.rows) {
            TableColumn(Text(verbatim: "")) { $row in
                Toggle(isOn: $row.include) { EmptyView() }
                    .labelsHidden()
                    .disabled(row.hasError || model.isRunning)
            }
            .width(24)
            TableColumn("Doména") { $row in
                HStack(spacing: 4) {
                    Text(verbatim: row.candidate.vhost.domain)
                    if row.candidate.source == .sslOnly {
                        Text("len HTTPS")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(.orange.opacity(0.2), in: .capsule)
                    }
                }
            }
            .width(min: 160, ideal: 200)
            TableColumn("Aliasy") { $row in
                Text(verbatim: row.candidate.vhost.aliases.joined(separator: ", "))
                    .lineLimit(1)
                    .help(row.candidate.vhost.aliases.joined(separator: "\n"))
            }
            .width(min: 80, ideal: 140)
            TableColumn("Docroot") { $row in
                Text(verbatim: row.candidate.vhost.docroot)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(row.candidate.vhost.docroot)
            }
            .width(min: 120, ideal: 220)
            TableColumn("PHP") { $row in
                Picker(selection: $row.phpBranch) {
                    Text("Predvolená").tag(String?.none)
                    ForEach(model.phpBranches, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .help(Text(verbatim: row.candidate.mampPHPVersion.map { "MAMP: PHP \($0)" } ?? ""))
            }
            .width(min: 90, ideal: 110)
            TableColumn("Problémy") { $row in
                IssuesCell(issues: row.candidate.issues)
            }
            .width(min: 60, ideal: 80)
        }
    }

    @ViewBuilder private var skippedSection: some View {
        if let skipped = model.plan?.skipped, !skipped.isEmpty {
            DisclosureGroup(isExpanded: $showSkipped) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(skipped.enumerated()), id: \.offset) { _, host in
                        HStack {
                            Text(verbatim: host.serverName).font(.callout.monospaced())
                            Text(reason(host.reason)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Preskočené (\(skipped.count))")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func reason(_ r: ImportSkipReason) -> LocalizedStringKey {
        switch r {
        case .catchAll: "predvolený catch-all vhost"
        case .reservedLocalhost: "localhost patrí RAMP"
        case .redirectOnly: "len presmerovanie"
        case .existsInRamp: "už existuje v RAMP"
        case .duplicate: "duplicitný záznam"
        case .noServerName: "bez ServerName"
        }
    }

    private func resultView(_ result: VhostChangeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Importovaných vhostov: \(model.wizard.importedVhosts.count)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            switch result.hosts {
            case .pending(let reason):
                Label {
                    VStack(alignment: .leading) {
                        Text("Súbor /etc/hosts nie je aktuálny")
                        Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Button("Zopakovať zápis do /etc/hosts") { Task { await model.app?.syncHosts() } }
            case .synced, .notManaged:
                EmptyView()
            }
            if !result.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, w in
                            Text(verbatim: "• \(w.message)").font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IssuesCell: View {
    let issues: [VhostIssue]

    var body: some View {
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        HStack(spacing: 6) {
            if errors > 0 {
                Label { Text(verbatim: "\(errors)") } icon: { Image(systemName: "xmark.octagon.fill") }
                    .foregroundStyle(.red)
            }
            if warnings > 0 {
                Label { Text(verbatim: "\(warnings)") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(.orange)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .help(issues.map(\.message).joined(separator: "\n"))
    }
}
