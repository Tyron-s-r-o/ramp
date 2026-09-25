import SwiftUI
import AppKit
import RAMPCore

/// Nastavenia › Terminál: status, PHP behind `php` (`cli.defaultPHP`), available commands, PATH block and
/// MAMP lines, Composer update.
struct TerminalSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.terminal
        Section {
            statusRow(model)
            Picker("PHP pre príkazy php a composer", selection: Binding(
                get: { app.config.cli.defaultPHP },
                set: { value in Task { await model.setDefault(value) } })) {
                Text("Automaticky (PHP \(model.defaultBranch ?? "—"))").tag(String?.none)
                ForEach(model.branches, id: \.self) { branch in
                    Text(verbatim: "PHP \(branch)").tag(String?.some(branch))
                }
            }
            if let status = model.status {
                ForEach(status.files, id: \.file) { file in
                    LabeledContent {
                        Image(systemName: file.hasBlock ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(file.hasBlock ? Color.green : Color.secondary)
                    } label: {
                        Text(verbatim: "~/" + file.file.lastPathComponent).font(.callout.monospaced())
                    }
                }
                if !status.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Riadky MAMPu prekrývajú RAMP (alias má prednosť pred PATH):", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        MAMPLinesList(lines: status.conflicts)
                    }
                }
                if !status.disabledLines.isEmpty {
                    Text("RAMP vypol riadky MAMPu: \(status.disabledLines.count) — dajú sa obnoviť.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            commandsRow(model)
            LabeledContent("Composer") {
                HStack {
                    if let date = model.composerDate {
                        Text("Stiahnutý \(date.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nestiahnutý").foregroundStyle(.secondary)
                    }
                    Button("Aktualizovať Composer") { Task { await model.updateComposer() } }
                        .disabled(model.isWorking)
                }
            }
        } header: {
            Text("Terminál")
        } footer: {
            HStack {
                if let message = model.lastMessage {
                    Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Obnoviť riadky MAMPu") { Task { await model.restoreMAMP() } }
                    .disabled(model.isWorking || (model.status?.disabledLines.isEmpty ?? true))
                Button("Odstrániť") { Task { await model.remove() } }
                    .disabled(model.isWorking || !(model.status?.anyBlock ?? false))
                Button("Nastaviť") { Task { await model.setUp() } }
                    .disabled(model.isWorking)
            }
        }
        .task { await model.refresh() }
    }

    private func statusRow(_ model: TerminalModel) -> some View {
        LabeledContent {
            HStack {
                if model.isProbing {
                    ProgressView().controlSize(.small)
                } else if model.resolvesToRAMP {
                    Label("RAMP", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let probed = model.probed {
                    Text(verbatim: probed)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else {
                    Text("Nenastavené").foregroundStyle(.secondary)
                }
                Button("Skontrolovať") { Task { await model.refresh() } }
                    .disabled(model.isProbing)
            }
        } label: {
            Text("php v novom termináli")
        }
    }

    private func commandsRow(_ model: TerminalModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dostupné príkazy")
                Spacer()
                Button("Kopírovať") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.commands.joined(separator: "\n"), forType: .string)
                }
                .disabled(model.commands.isEmpty)
            }
            Text(verbatim: model.commands.isEmpty ? "—" : model.commands.joined(separator: "  "))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("V ~/.ramp/bin. Composer inou verziou PHP: RAMP_PHP=8.3 composer …")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Exact MAMP lines (file:line + text), selectable.
struct MAMPLinesList: View {
    let lines: [MAMPLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: "~/\(line.file?.lastPathComponent ?? "?"):\(line.index + 1)  \(line.text)")
                    .font(.caption.monospaced())
                    .foregroundStyle(line.disableable ? Color.primary : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// First launch / once for existing installs: set up the terminal, listing MAMP lines that would be disabled.
struct TerminalPromptSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = app.terminal
        let conflicts = model.status?.blockingConflicts ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminál: php, composer a mysql z RAMP").font(.headline)
            Text("RAMP pridá ~/.ramp/bin na koniec PATH v ~/.zprofile a ~/.zshrc, aby príkazy php, php8.3, composer, mysql a redis-cli v novom termináli spúšťali RAMP.")
                .fixedSize(horizontal: false, vertical: true)
            if !conflicts.isEmpty {
                Text("Tieto riadky MAMPu by mali prednosť. RAMP ich zakomentuje (nič nezmaže, dajú sa obnoviť v Nastaveniach › Terminál):")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    MAMPLinesList(lines: conflicts).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Neskôr") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    Task { await model.install(disableMAMP: true) }
                } label: {
                    conflicts.isEmpty ? Text("Nastaviť terminál") : Text("Vypnúť riadky MAMPu a použiť RAMP")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await model.refresh(probe: false) }
    }
}
