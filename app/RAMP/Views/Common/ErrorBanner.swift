import SwiftUI

/// Dismissible error strip above the detail view: Slovak title + verbatim core message (selectable).
struct ErrorBanner: View {
    let error: UserFacingError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: error.title).bold()
                // Messages can be long (config-test output); cap the banner height so it can never
                // push the rest of the window off-screen.
                ScrollView(.vertical) {
                    Text(verbatim: error.message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Zavrieť"))
        }
        .padding(10)
        .background(.red.opacity(0.1))
    }
}
