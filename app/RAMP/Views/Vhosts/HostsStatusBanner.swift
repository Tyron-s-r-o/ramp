import SwiftUI

/// Hosts-file status above the vhost list: helper not approved (password prompts) and/or a pending sync.
struct HostsStatusBanner: View {
    let model: VhostsModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showHelperBanner {
                strip(icon: "lock.shield", tint: .orange) {
                    Text("Pomocník pre /etc/hosts nie je povolený — zmeny zapíšem cez výzvu na heslo")
                } action: {
                    Button("Povoliť pomocníka…") { Task { await model.approveHelper() } }
                }
            }
            if let reason = model.hostsPendingReason {
                strip(icon: "exclamationmark.triangle.fill", tint: .yellow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Súbor /etc/hosts nie je aktuálny").bold()
                        Text(verbatim: reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } action: {
                    Button("Skúsiť znova") { Task { await model.retryHosts() } }
                }
            }
        }
    }

    private func strip(icon: String, tint: Color, @ViewBuilder content: () -> some View,
                       @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
            action()
        }
        .padding(10)
        .background(tint.opacity(0.1))
    }
}
