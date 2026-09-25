import SwiftUI
import RAMPCore

/// Services › Voliteľné, ES not installed: "Nie je nainštalovaný" + "Nainštalovať…" (→ Nastavenia).
struct ElasticsearchNotInstalledRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: ServiceID.elasticsearch.displayName).font(.headline)
                    Text("Nie je nainštalovaný").foregroundStyle(.secondary)
                }
                if app.elasticsearch.installing {
                    PackageProgressView(stage: app.elasticsearch.installStage, download: app.elasticsearch.installDownload)
                        .frame(maxWidth: 420)
                } else {
                    Text("Voliteľná služba — nikdy sa nespúšťa automaticky.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Nainštalovať…") { app.selection = .settings }
                .disabled(app.elasticsearch.installing)
        }
        .padding(.vertical, 4)
    }
}

/// ES row extras in the Services section: heap + "Auto-stop o 01:00 (zostáva 3 h 05 min)" + "Predĺžiť o 1 h".
struct ElasticsearchAutoStopLine: View {
    @Environment(AppModel.self) private var app
    let state: ServiceState

    var body: some View {
        let es = app.elasticsearch
        HStack(spacing: 14) {
            Text("Heap \(es.settings.heap)")
            if state.isRunning {
                AutoStopRemainingText(status: es.autoStop)
                if es.autoStop.deadline != nil {
                    Button("Predĺžiť o 1 h") { Task { await es.postpone() } }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// "Auto-stop o 01:00 (zostáva 3 h 05 min)" / "Auto-stop vypnutý", refreshed every minute.
struct AutoStopRemainingText: View {
    let status: AutoStopStatus

    var body: some View {
        if let deadline = status.deadline {
            TimelineView(.everyMinute) { context in
                let clock = ElasticsearchModel.clock(deadline)
                let remaining = ElasticsearchModel.remaining(until: deadline, now: context.date)
                Text("Auto-stop o \(clock) (zostáva \(remaining))")
            }
            .help(helpText)
        } else if status.isActive {
            Text("Auto-stop vypnutý")
        }
    }

    private var helpText: Text {
        switch status.reason {
        case .afterHours(let h): Text("Po \(h) h behu")
        case .atTime(let t): Text("V čase \(t.description)")
        case .postponed: Text("Predĺžené")
        case nil: Text(verbatim: "")
        }
    }
}

/// Menu bar ES row extras: remaining time + "+1 h" when running.
struct MenuElasticsearchExtras: View {
    @Environment(AppModel.self) private var app
    let state: ServiceState

    var body: some View {
        let es = app.elasticsearch
        if state.isRunning {
            HStack(spacing: 6) {
                AutoStopRemainingText(status: es.autoStop)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if es.autoStop.deadline != nil {
                    Button("+1 h") { Task { await es.postpone() } }
                        .controlSize(.mini)
                        .help("Predĺžiť o 1 h")
                }
            }
            .padding(.leading, 17)
        }
    }
}
