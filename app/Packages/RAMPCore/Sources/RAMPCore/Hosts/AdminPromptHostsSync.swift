import Foundation
import RAMPHostsKit

/// Runs an AppleScript (`/usr/bin/osascript -e <script>`). Injectable so tests never prompt.
public protocol AppleScriptRunning: Sendable {
    func run(_ script: String) async -> (status: Int32, output: String)
}

public struct OsascriptRunner: AppleScriptRunning {
    let tempDir: URL

    public init(tempDir: URL) { self.tempDir = tempDir }

    public func run(_ script: String) async -> (status: Int32, output: String) {
        let result = await ProcessRunner.run(["/usr/bin/osascript", "-e", script], tempDir: tempDir)
        return (result.status, result.output)
    }
}

/// Fallback without the helper (rampctl, ad-hoc builds, helper not approved): renders the complete new
/// hosts content with `HostsBlock.merge` into a RAMP-owned temp file and installs it with
/// `osascript … with administrator privileges` — the user gets a password prompt every time, so it is
/// only called when something actually changes (see `HostsSyncCoordinator`).
public struct AdminPromptHostsSync: HostsSyncing {
    public let paths: Paths
    /// Target hosts file; the system file unless a test passes another one.
    public let hostsPath: String
    private let runner: any AppleScriptRunning

    public init(paths: Paths, hostsPath: String = HostsFileWriter.systemHostsPath,
                runner: (any AppleScriptRunning)? = nil) {
        self.paths = paths
        self.hostsPath = hostsPath
        self.runner = runner ?? OsascriptRunner(tempDir: paths.tmp)
    }

    public func apply(names: [String]) async throws -> HostsSyncOutcome {
        let current = try HostsFileWriter(path: URL(filePath: hostsPath)).read()
        let merged = try HostsBlock.merge(existing: current, names: names)
        if merged == current { return .unchanged }

        let fm = FileManager.default
        try fm.createDirectory(at: paths.tmp, withIntermediateDirectories: true)
        let tmp = paths.tmp.appending(path: "hosts.\(UUID().uuidString)", directoryHint: .notDirectory)
        let tmpPath = tmp.path(percentEncoded: false)
        defer { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmpPath, contents: Data(merged.utf8), attributes: [.posixPermissions: 0o644]) else {
            throw HostsSyncError.commandFailed("cannot write \(tmpPath)")
        }
        // createFile honours the umask; make sure `install` copies a 0644 file either way.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmpPath)

        let result = await runner.run(Self.script(tempFile: tmpPath, target: hostsPath))
        if result.status != 0 {
            if result.output.contains("-128") { throw HostsSyncError.cancelled }
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostsSyncError.commandFailed(text.isEmpty ? "osascript exit \(result.status)" : text)
        }
        return .updated(via: .adminPrompt)
    }

    /// `do shell script "/usr/bin/install -m 0644 -o root -g wheel " & quoted form of "<tmp>" & " " &
    /// quoted form of "<target>" & " && dscacheutil … && killall -HUP mDNSResponder" with administrator privileges`
    static func script(tempFile: String, target: String) -> String {
        "do shell script \"/usr/bin/install -m 0644 -o root -g wheel \" & quoted form of \(literal(tempFile))"
            + " & \" \" & quoted form of \(literal(target))"
            + " & \" && /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder\""
            + " with administrator privileges"
    }

    /// AppleScript string literal: `\` and `"` escaped.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
