import Foundation
import Observation
import RAMPCore

/// One displayed log line.
struct LogLine: Identifiable, Equatable {
    enum Level { case normal, warning, error }

    let id: Int
    let text: String
    let level: Level

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        level = Self.level(of: text)
    }

    private static let errorWords = ["error", "fatal", "emerg", "crit"]
    private static let warningWords = ["warn", "notice", "deprecated"]

    static func level(of text: String) -> Level {
        let lower = text.lowercased()
        if errorWords.contains(where: lower.contains) { return .error }
        if warningWords.contains(where: lower.contains) { return .warning }
        return .normal
    }
}

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all, errors
    var id: String { rawValue }
}

/// Owns the reader off the main actor; the model only awaits it.
private actor LogFollower {
    private var reader: LogTailReader

    init(url: URL) { reader = LogTailReader(url: url) }

    func initial() throws -> [String] { try reader.initial() }
    func poll() throws -> LogTailReader.PollResult { try reader.poll() }
}

/// State of the Logs section: file list, selected file, ring buffer of lines, filters.
@MainActor @Observable
final class LogsModel {
    static let maxLines = 5000

    private(set) var files: [LogFile] = []
    var selected: URL?
    private(set) var lines: [LogLine] = []
    var filter = ""
    var follow = true
    var levelFilter: LogLevelFilter = .all
    private(set) var readError: String?

    @ObservationIgnored let logsDir: URL
    @ObservationIgnored private var nextID = 0

    init(logsDir: URL) {
        self.logsDir = logsDir
    }

    var selectedFile: LogFile? { files.first { $0.url == selected } }

    var visibleLines: [LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return lines.filter { line in
            (levelFilter == .all || line.level == .error)
                && (needle.isEmpty || line.text.localizedCaseInsensitiveContains(needle))
        }
    }

    // MARK: File list

    func refreshFiles() async {
        let dir = logsDir
        let list = await Task.detached { LogCatalog.files(in: dir) }.value
        files = list
        if selected == nil { selected = list.first?.url }
    }

    /// Refreshes the list every 5 s until cancelled (bound to the view's `.task`).
    func runFileRefresh() async {
        while !Task.isCancelled {
            await refreshFiles()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Services "Log" button: preferred file of the service, else its supervisor log `<service>.log`.
    func select(service id: ServiceID) {
        let fm = FileManager.default
        let preferred = logsDir.appending(path: LogCatalog.preferredFileName(for: id))
        let fallback = logsDir.appending(path: "\(id.name).log")
        if !fm.fileExists(atPath: preferred.path(percentEncoded: false)),
           fm.fileExists(atPath: fallback.path(percentEncoded: false)) {
            selected = fallback
        } else {
            selected = preferred
        }
    }

    // MARK: Follow

    /// Loads the tail of the selected file, then polls every 500 ms until cancelled
    /// (the view restarts it via `.task(id: selected)` when the selection changes / the section disappears).
    func runFollow() async {
        clear()
        readError = nil
        guard let url = selected else { return }
        let follower = LogFollower(url: url)
        do {
            append(try await follower.initial())
        } catch {
            readError = error.localizedDescription
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                let result = try await follower.poll()
                if result.reset { clear() }
                append(result.lines)
                readError = nil
            } catch {
                readError = error.localizedDescription
            }
        }
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
    }

    private func append(_ new: [String]) {
        guard !new.isEmpty else { return }
        let batch = new.suffix(Self.maxLines).map { text -> LogLine in
            defer { nextID += 1 }
            return LogLine(id: nextID, text: text)
        }
        let overflow = lines.count + batch.count - Self.maxLines
        if overflow > 0 { lines.removeFirst(min(overflow, lines.count)) }
        lines.append(contentsOf: batch)
    }
}
