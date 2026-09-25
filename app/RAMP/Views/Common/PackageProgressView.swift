import SwiftUI
import RAMPCore

/// Determinate package-install bar + status line under it (ES install, first-launch install, updates):
/// "Sťahuje sa… 412 MB / 670 MB · 11,2 MB/s · zostáva 0:23", then "Overuje sa kontrolný súčet…", "Rozbaľuje sa…".
struct PackageProgressView: View {
    let stage: InstallProgress.Stage?
    let download: DownloadProgress?
    /// Optional leading label ("Apache 2.4") in front of the status line.
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: InstallProgress.overallFraction(stage: stage, download: download))
            HStack(spacing: 4) {
                if let title { Text(verbatim: title).fontWeight(.medium) }
                Self.status(stage: stage, download: download)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    static func status(stage: InstallProgress.Stage?, download: DownloadProgress?) -> Text {
        switch stage {
        case .downloading, nil: downloading(download)
        case .verifying: Text("Overuje sa kontrolný súčet…")
        case .extracting: Text("Rozbaľuje sa…")
        case .activating: Text("Aktivuje sa…")
        case .installed: Text("Nainštalované")
        case .failed: Text("Inštalácia zlyhala")
        }
    }

    /// "Sťahuje sa… 412 MB / 670 MB · 11,2 MB/s · zostáva 0:23" (parts dropped while unknown).
    static func downloading(_ download: DownloadProgress?) -> Text {
        guard let download else { return Text("Sťahuje sa…") }
        let received = DownloadProgress.bytes(download.bytesReceived)
        let speed = download.bytesPerSecond.map { DownloadProgress.speed($0) }
        if let total = download.totalBytes.map({ DownloadProgress.bytes($0) }) {
            if let speed, let eta = download.secondsRemaining.map(DownloadProgress.duration) {
                return Text("Sťahuje sa… \(received) / \(total) · \(speed)/s · zostáva \(eta)")
            }
            return Text("Sťahuje sa… \(received) / \(total)")
        }
        if let speed { return Text("Sťahuje sa… \(received) · \(speed)/s") }
        return Text("Sťahuje sa… \(received)")
    }
}
