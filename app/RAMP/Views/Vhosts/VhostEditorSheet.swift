import SwiftUI
import UniformTypeIdentifiers
import RAMPCore

/// Add / edit a vhost. Live inline validation (read-only checks); save runs the full `VhostService` pipeline.
struct VhostEditorSheet: View {
    let model: VhostsModel
    @State private var draft: VhostDraft
    @State private var serverIssues: [VhostIssue] = []
    @State private var pickingFolder = false
    /// Set once the user types / picks a group — from then on a new docroot no longer re-suggests it.
    @State private var groupTouched = false
    @Environment(\.dismiss) private var dismiss

    init(model: VhostsModel, draft: VhostDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let issues = liveIssues
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Doména", text: $draft.domain, prompt: Text(verbatim: "projekt"))
                    let normalized = model.normalizedDomain(draft.domain)
                    if !normalized.isEmpty {
                        Text("Adresa: http://\(normalized)/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    IssueList(issues: issues, field: .domain)
                }

                Section("Aliasy") {
                    ForEach($draft.aliases) { $alias in
                        HStack {
                            TextField("Alias", text: $alias.name, prompt: Text(verbatim: "admin.projekt"))
                                .labelsHidden()
                            Button {
                                draft.aliases.removeAll { $0.id == alias.id }
                            } label: {
                                Label("Odstrániť alias", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Odstrániť alias")
                        }
                    }
                    Button {
                        draft.aliases.append(.init(name: ""))
                    } label: {
                        Label("Pridať alias", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    IssueList(issues: issues, field: .alias)
                }

                Section {
                    LabeledContent("Docroot") {
                        HStack {
                            Text(draft.docroot.isEmpty ? String(localized: "Nevybraný") : draft.docroot)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(draft.docroot.isEmpty ? .secondary : .primary)
                                .help(Text(verbatim: draft.docroot))
                                .textSelection(.enabled)
                            Button("Vybrať…") { pickingFolder = true }
                        }
                    }
                    IssueList(issues: issues, field: .docroot)

                    Picker("PHP verzia", selection: $draft.phpBranch) {
                        if let fallback = model.defaultPHPBranch {
                            Text("Predvolená (\(fallback))").tag(String?.none)
                        } else {
                            Text("Predvolená").tag(String?.none)
                        }
                        ForEach(branchChoices, id: \.self) { branch in
                            Text(verbatim: "PHP \(branch)").tag(String?.some(branch))
                        }
                    }
                    IssueList(issues: issues, field: .php)

                    LabeledContent("Skupina") {
                        HStack(spacing: 4) {
                            TextField("Skupina", text: groupBinding, prompt: Text("Bez skupiny"))
                                .labelsHidden()
                            Menu {
                                ForEach(model.groups, id: \.self) { group in
                                    Button(group) { setGroup(group) }
                                }
                                if !model.groups.isEmpty { Divider() }
                                if let suggestion = model.suggestedGroup(docroot: draft.docroot),
                                   !model.groups.contains(suggestion) {
                                    Button("Podľa priečinka: \(suggestion)") { setGroup(suggestion) }
                                }
                                Button("Bez skupiny") { setGroup("") }
                            } label: {
                                Label("Existujúce skupiny", systemImage: "folder")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Existujúce skupiny")
                        }
                    }
                    IssueList(issues: issues, field: .group)

                    Toggle("Zapnutý", isOn: $draft.enabled)
                    IssueList(issues: issues, field: .limits)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.saving {
                    ProgressView().controlSize(.small)
                    Text("Ukladám a načítavam Apache…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Zrušiť") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Pridať" : "Uložiť") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave(issues))
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            // Not sandboxed → a plain path is enough, no security-scoped bookmark.
            if case .success(let url) = result {
                draft.docroot = url.path(percentEncoded: false)
            }
        }
        .onChange(of: draft.docroot) {
            // New vhost: propose the Sites folder as the group until the user sets one himself.
            if draft.isNew && !groupTouched {
                draft.group = model.suggestedGroup(docroot: draft.docroot) ?? ""
            }
        }
        .onChange(of: draft) { serverIssues = [] }
        .interactiveDismissDisabled(model.saving)
    }

    private var groupBinding: Binding<String> {
        Binding(get: { draft.group }, set: { setGroup($0) })
    }

    private func setGroup(_ group: String) {
        draft.group = group
        groupTouched = true
    }

    /// Installed + enabled branches, plus the draft's current branch when it is no longer available.
    private var branchChoices: [String] {
        var branches = model.phpBranches
        if let current = draft.phpBranch, !branches.contains(current) { branches.append(current) }
        return branches
    }

    /// Server issues (after a rejected save) replace the live ones until the draft changes.
    private var liveIssues: [VhostIssue] {
        serverIssues.isEmpty ? model.preview(draft) : serverIssues
    }

    private func canSave(_ issues: [VhostIssue]) -> Bool {
        !model.saving
            && !draft.domain.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.docroot.isEmpty
            && !issues.contains { $0.severity == .error }
    }

    private func cancel() {
        guard !model.saving else { return }
        model.editor = nil
        dismiss()
    }

    private func save() async {
        switch await model.save(draft) {
        case .saved: dismiss()
        case .invalid(let issues): serverIssues = issues
        case .failed: break
        }
    }
}

/// Issues of one field: errors red, warnings yellow (non-blocking).
private struct IssueList: View {
    let issues: [VhostIssue]
    let field: VhostIssue.Field

    var body: some View {
        ForEach(Array(issues.filter { $0.field == field }.enumerated()), id: \.offset) { _, issue in
            Label {
                Text(verbatim: issue.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
        }
    }
}
