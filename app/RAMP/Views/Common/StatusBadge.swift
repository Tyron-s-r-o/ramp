import SwiftUI
import RAMPCore

/// Stack health pill (toolbar). Same levels as the menu-bar icon (05-05).
struct StatusBadge: View {
    let health: StackHealth

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            if health.xdebugOn {
                Text("Xdebug").font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .background(.orange.opacity(0.25), in: .capsule)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch health.level {
        case .allRunning: "Všetko beží"
        case .partial: "Čiastočne beží"
        case .error: "Chyba"
        case .stopped: "Zastavené"
        }
    }

    private var color: Color {
        switch health.level {
        case .allRunning: .green
        case .partial: .yellow
        case .error: .red
        case .stopped: .secondary
        }
    }
}

/// Colored dot for one service state.
struct StateDot: View {
    let state: ServiceState

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .starting, .stopping, .backingOff: .yellow
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
