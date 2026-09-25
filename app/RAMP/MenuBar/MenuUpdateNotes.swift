import SwiftUI
import RAMPCore

/// Menu-bar header rows for applied updates (07-02): the in-app note after automatic PHP patches and a persistent
/// warning row for failed / rolled-back updates (opens Nastavenia).
struct MenuUpdateNotes: View {
    @Environment(AppModel.self) private var app
    let openSettings: () -> Void

    var body: some View {
        let engine = app.updates.apply
        if engine.isApplying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Prebieha aktualizácia…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let note = engine.note {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: note).font(.caption)
                Spacer()
                Button {
                    engine.dismissNote()
                } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(Text("Zavrieť"))
            }
        }
        if !engine.warnings.isEmpty {
            Button(action: openSettings) {
                Label("Aktualizácia zlyhala – podrobnosti v Nastaveniach", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: engine.warnings.joined(separator: "\n")))
        }
    }
}
