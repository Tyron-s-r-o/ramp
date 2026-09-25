import SwiftUI
import RAMPCore

struct ServiceRow: View {
    @Environment(AppModel.self) private var app
    let row: ServiceRowState

    var body: some View {
        let services = app.services
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Leading slot = width of the PHP-FPM group's disclosure chevron → all status dots align.
            Color.clear.frame(width: ServiceRowMetrics.chevronSlot, height: 1)
            StateDot(state: row.state)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.displayName).font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        stateText(now: context.date)
                            .foregroundStyle(.secondary)
                    }
                }
                details
                if row.id == .elasticsearch { ElasticsearchAutoStopLine(state: row.state) }   // 06-04
                if case .failed(let reason) = row.state {
                    Text(verbatim: reason)
                        .font(.callout.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .help(Text(verbatim: reason))
                }
            }
            Spacer(minLength: 8)
            actions(services)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var details: some View {
        HStack(spacing: 14) {
            if let pid = row.state.pid {
                Text("PID \(String(pid))")
            }
            if let port = row.port {
                Text("Port \(String(port))")
            }
            if let since = row.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Beží \(Self.uptime(since: since, now: context.date))")
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func stateText(now: Date) -> Text {
        switch row.state {
        case .running: Text("Beží")
        case .starting: Text("Spúšťa sa")
        case .stopping: Text("Zastavuje sa")
        case .stopped: Text("Zastavené")
        case .backingOff(let attempt, let until):
            Text("Reštart o \(max(0, Int(until.timeIntervalSince(now).rounded(.up)))) s (pokus \(attempt))")
        case .failed: Text("Chyba")
        }
    }

    @ViewBuilder private func actions(_ services: ServicesModel) -> some View {
        let id = row.id
        let locked = row.isTransitioning || services.isBusyAll
        HStack(spacing: 6) {
            switch row.state {
            case .running, .starting, .backingOff:
                Button {
                    Task { await services.stop(id) }
                } label: {
                    Label("Zastaviť", systemImage: "stop.fill")
                }
                .disabled(locked || services.isBusy("stop", id))
            default:
                Button {
                    Task { await services.start(id) }
                } label: {
                    Label("Spustiť", systemImage: "play.fill")
                }
                .disabled(locked || services.isBusy("start", id))
            }
            Button {
                Task { await services.restart(id) }
            } label: {
                Label("Reštart", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(locked || services.isBusy("restart", id))
            if row.isReloadable {
                Button {
                    Task { await services.reload(id) }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(locked || !row.state.isRunning || services.isBusy("reload", id))
                .help("Graceful reload konfigurácie")
            }
            Button {
                app.showLog(for: id)
            } label: {
                Label("Log", systemImage: "doc.text")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .overlay(alignment: .leading) {
            if isAnyBusy(services) {
                ProgressView().controlSize(.small).offset(x: -22)
            }
        }
    }

    private func isAnyBusy(_ services: ServicesModel) -> Bool {
        ["start", "stop", "restart", "reload"].contains { services.isBusy($0, row.id) }
    }

    static func uptime(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}


enum ServiceRowMetrics {
    static let chevronSlot: CGFloat = 12
}
