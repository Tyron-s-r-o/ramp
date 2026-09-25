import SwiftUI
import RAMPCore

/// Add / edit one php.ini override. Validation errors (syntax, protected key, control characters) and
/// apply errors are shown inline; a global change asks for confirmation (reloads every PHP branch).
struct IniOverrideSheet: View {
    enum Scope: Hashable {
        case branch, global
    }

    enum Mode: Identifiable, Hashable {
        case add
        case edit(key: String, value: String, scope: Scope)

        var id: String {
            switch self {
            case .add: "+"
            case .edit(let key, _, _): key
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    /// nil = the "Globálne" entry (scope fixed to global).
    let branch: String?

    @State private var key = ""
    @State private var value = ""
    @State private var scope: Scope = .branch
    @State private var error: String?
    @State private var confirmGlobal = false
    @State private var saving = false

    private var isEdit: Bool { if case .edit = mode { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Upraviť direktívu" : "Pridať direktívu").font(.headline)
            Form {
                TextField("Direktíva", text: $key, prompt: Text(verbatim: "memory_limit"))
                    .font(.body.monospaced())
                    .disabled(isEdit)
                TextField("Hodnota", text: $value, prompt: Text(verbatim: "1024M"))
                    .font(.body.monospaced())
                if let branch {
                    Picker("Platí pre", selection: $scope) {
                        Text("PHP \(branch)").tag(Scope.branch)
                        Text("Všetky verzie").tag(Scope.global)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            if scope == .global {
                Label("Znovu načíta všetky PHP verzie", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(verbatim: error)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Zrušiť", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Uložiť") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
        .confirmationDialog(Text("Zmeniť direktívu pre všetky PHP verzie?"), isPresented: $confirmGlobal) {
            Button("Uložiť a znovu načítať") { Task { await save() } }
        } message: {
            Text("Znovu načíta všetky PHP verzie")
        }
    }

    private func load() {
        switch mode {
        case .add:
            scope = branch == nil ? .global : .branch
        case .edit(let k, let v, let s):
            key = k
            value = v
            scope = branch == nil ? .global : s
        }
    }

    /// Local validation first (inline), then confirmation for the global scope.
    private func submit() {
        let k = key.trimmingCharacters(in: .whitespaces)
        if PHPIniLayers.isProtected(k) {
            error = String(localized: "Spravuje RAMP — použi prepínače OPcache/APCu/Xdebug/Rozšírenia")
            return
        }
        do {
            try PHPIniLayers.validate(key: k, value: value)
        } catch {
            self.error = String(localized: "Neplatná direktíva alebo hodnota: \(PHPModel.message(error))")
            return
        }
        error = nil
        if scope == .global { confirmGlobal = true } else { Task { await save() } }
    }

    private func save() async {
        let k = key.trimmingCharacters(in: .whitespaces)
        let target: PHPIniScope = if scope == .branch, let branch { .branch(branch) } else { .global }
        saving = true
        defer { saving = false }
        do {
            try await app.php.setIniOverride(scope: target, key: k, value: value)
            dismiss()
        } catch {
            self.error = PHPModel.message(error)
        }
    }
}
