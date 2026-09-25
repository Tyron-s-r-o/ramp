import SwiftUI
import RAMPCore

/// Nastavenia › Aktualizácie (owned by 07-02; embedded by 05-06's `SettingsView`): last check, "Skontrolovať teraz",
/// interval, auto-apply / dump toggles, plan grouped by kind with one-click apply + progress + last outcome incl.
/// rollback reason; new branches installable; migrations informational only.
struct UpdatesSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let updates = app.updates
        let engine = updates.apply
        let settings = app.config.updates
        Section("Aktualizácie") {
            HStack {
                if let checked = updates.lastChecked {
                    Text("Posledná kontrola: \(checked.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Ešte neprebehla kontrola")
                }
                Spacer()
                if updates.isChecking { ProgressView().controlSize(.small) }
                Button("Skontrolovať teraz") { Task { await updates.check() } }
                    .disabled(updates.isChecking || engine.isApplying)
            }
            if let error = updates.lastError {
                Text("Chyba kontroly: \(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Stepper(value: Binding(get: { settings.checkIntervalHours },
                                   set: { hours in Task { await engine.setInterval(hours) } }),
                    in: UpdateSettings.intervalRange) {
                Text("Interval kontroly: \(settings.checkIntervalHours) h")
            }
            Toggle("Automaticky inštalovať opravy PHP",
                   isOn: Binding(get: { settings.autoApplyPHPPatches },
                                 set: { on in Task { await engine.setAutoApplyPHPPatches(on) } }))
            Toggle("Pred aktualizáciou MySQL urobiť zálohu (mysqldump)",
                   isOn: Binding(get: { settings.dumpBeforeMySQLPatch },
                                 set: { on in Task { await engine.setDumpBeforeMySQLPatch(on) } }))
            ForEach(engine.warnings, id: \.self) { warning in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(verbatim: warning).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Zavrieť") { engine.dismissWarning(warning) }.controlSize(.small)
                }
            }
        }

        let updatable = engine.offered
        let branches = engine.plan.items.filter { $0.kind == .newBranch }
        let migrations = engine.plan.items.filter { $0.kind == .migration }
        Section("Aktualizácie služieb") {
            if updatable.isEmpty {
                Text("Všetko je aktuálne").foregroundStyle(.secondary)
            }
            ForEach(updatable, id: \.self) { item in
                UpdateItemRow(item: item) {
                    Button("Aktualizovať") { Task { await engine.apply(item) } }
                        .disabled(engine.isApplying)
                }
            }
            if updatable.count > 1 {
                Button("Aktualizovať všetko") { Task { await engine.applyAll() } }
                    .disabled(engine.isApplying)
            }
        }
        if !branches.isEmpty {
            Section("Nové vetvy") {
                ForEach(branches, id: \.self) { item in
                    UpdateItemRow(item: item) {
                        Button("Inštalovať vetvu") { Task { await engine.apply(item) } }
                            .disabled(engine.isApplying)
                    }
                }
            }
        }
        if !migrations.isEmpty {
            Section("Migrácie") {
                ForEach(migrations, id: \.self) { item in
                    UpdateItemRow(item: item) { EmptyView() }
                }
                Text("Prechod na novú hlavnú verziu MySQL je migrácia (záloha + upgrade dát) – nerieši sa tu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One plan item: name, installed → available, running step or last outcome, trailing action.
private struct UpdateItemRow<Action: View>: View {
    @Environment(AppModel.self) private var app
    let item: UpdateItem
    @ViewBuilder let action: () -> Action

    var body: some View {
        let engine = app.updates.apply
        let key = UpdateApplyModel.key(item)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: UpdateApplyModel.displayName(item)).fontWeight(.medium)
                    Text(verbatim: "\(item.from ?? "—") → \(item.to)").foregroundStyle(.secondary).monospacedDigit()
                    if item.kind == .automatic {
                        Text("automaticky").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if case .downloadingBytes(let download) = engine.progress[key] {
                    PackageProgressView(stage: .downloading, download: download).frame(maxWidth: 360)
                } else if let step = engine.progress[key] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(Self.describe(step)).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let outcome = engine.outcomes[key] {
                    Text(verbatim: Self.describe(outcome))
                        .font(.caption)
                        .foregroundStyle(outcome.succeeded ? Color.secondary : Color.orange)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if engine.progress[key] == nil { action() }
        }
    }

    static func describe(_ step: UpdateProgress) -> LocalizedStringKey {
        switch step {
        case .waitingForLock: "Čaká sa…"
        case .dumping: "Záloha MySQL…"
        case .downloading, .downloadingBytes: "Sťahuje sa…"
        case .verifying: "Overuje sa kontrolný súčet…"
        case .extracting: "Rozbaľuje sa…"
        case .stopping: "Zastavuje sa služba…"
        case .activating: "Prepína sa verzia…"
        case .restarting: "Reštartuje sa…"
        case .checking: "Kontroluje sa…"
        case .rollingBack: "Vracia sa späť…"
        case .finished: "Hotovo"
        }
    }

    static func describe(_ outcome: UpdateOutcome) -> String {
        switch outcome {
        case .updated(nil, let to): String(localized: "Nainštalované \(to)")
        case .updated(_, let to): String(localized: "Aktualizované na \(to)")
        case .rolledBack(let to, let reason): String(localized: "Vrátené na \(to): \(reason)")
        case .failed: String(localized: "Zlyhalo: \(outcome.message)")
        }
    }
}
