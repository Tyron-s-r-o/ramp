import Darwin
import Foundation

/// A MAMP line in a shell startup file that would shadow RAMP's shims (`/Applications/MAMP` in a PATH
/// assignment or in an alias for php/composer/mysql/…). Aliases beat PATH, so they must be disabled.
public struct MAMPLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// `export PATH=…` / `path=(…)` whose entries are only MAMP dirs and `$PATH` → disableable.
        case path
        /// PATH assignment mixing MAMP with other directories — left alone (RAMP's block comes later and wins).
        case mixedPath
        /// `alias <name>=…/Applications/MAMP/…`.
        case alias(String)
    }

    public var file: URL?
    /// 0-based line index in the file.
    public var index: Int
    public var text: String
    public var kind: Kind

    public var disableable: Bool { kind != .mixedPath }

    public init(file: URL? = nil, index: Int, text: String, kind: Kind) {
        self.file = file
        self.index = index
        self.text = text
        self.kind = kind
    }
}

/// PATH integration for `~/.ramp/bin`: a managed block at the END of the shell startup files (so it wins over
/// earlier PATH edits) + reversible disabling of MAMP lines. Text transforms are pure and static (TDD); the
/// file side keeps a one-time `<file>.ramp-backup-YYYYMMDD-HHMMSS` before the first modification, writes
/// through symlinked dotfiles and never deletes a user line.
public struct ShellIntegration: Sendable {
    public static let blockStart = "# >>> RAMP >>>"
    public static let blockEnd = "# <<< RAMP <<<"
    public static let disabledPrefix = "# [RAMP disabled MAMP] "
    public static let backupInfix = ".ramp-backup-"
    /// Commands whose MAMP aliases shadow RAMP's shims.
    static let aliasNames: Set<String> = ["php", "composer", "phpize", "php-config", "pecl", "pear", "phpdbg",
                                          "mysql", "mysqldump", "mysqladmin", "mysqlcheck", "redis-cli"]
    static let mampMarker = "/Applications/MAMP"

    public let home: URL

    public init(home: URL) { self.home = home }

    /// `$HOME` (absolute) when set, else the account's home — sandbox tests run with `HOME=/tmp/…`.
    public static func standardHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["HOME"], h.hasPrefix("/") { return URL(filePath: h, directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.ramp` (no spaces, unlike Application Support).
    public var rampDir: URL { home.appending(path: ".ramp", directoryHint: .isDirectory) }
    public var shimDir: URL { rampDir.appending(path: "bin", directoryHint: .isDirectory) }

    // MARK: - Pure text transforms

    /// The managed block (no trailing newline).
    public static var block: String {
        [blockStart,
         "# Managed by RAMP: php, composer, mysql, redis-cli from RAMP (~/.ramp/bin). Removed by RAMP's uninstall.",
         "export PATH=\"$HOME/.ramp/bin:$PATH\"",
         blockEnd].joined(separator: "\n")
    }

    /// `text` with every RAMP block removed and the block appended at the end. Idempotent.
    public static func insertingBlock(into text: String) -> String {
        let base = removingBlock(from: text)
        let trimmed = trimTrailingBlankLines(base)
        return trimmed.isEmpty ? block + "\n" : trimmed + "\n\n" + block + "\n"
    }

    /// `text` without RAMP blocks (trailing blank lines left by the removal are trimmed). Unchanged when absent.
    public static func removingBlock(from text: String) -> String {
        guard containsBlock(text) else { return text }
        var out: [Substring] = []
        var inside = false
        for line in lines(text) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inside && t == blockStart { inside = true; continue }
            if inside {
                if t == blockEnd { inside = false }
                continue
            }
            out.append(line)
        }
        let joined = trimTrailingBlankLines(out.joined(separator: "\n"))
        return joined.isEmpty ? "" : joined + "\n"
    }

    public static func containsBlock(_ text: String) -> Bool {
        lines(text).contains { $0.trimmingCharacters(in: .whitespaces) == blockStart }
    }

    /// Active (not commented) MAMP lines that shadow RAMP.
    public static func mampConflicts(in text: String) -> [MAMPLine] {
        lines(text).enumerated().compactMap { i, line in
            classify(String(line)).map { MAMPLine(index: i, text: String(line), kind: $0) }
        }
    }

    /// Lines RAMP commented out earlier (text without the prefix).
    public static func disabledMAMPLines(in text: String) -> [MAMPLine] {
        lines(text).enumerated().compactMap { i, line in
            guard line.hasPrefix(disabledPrefix) else { return nil }
            let original = String(line.dropFirst(disabledPrefix.count))
            return MAMPLine(index: i, text: original, kind: classify(original) ?? .path)
        }
    }

    /// Comments out every disableable MAMP line with `disabledPrefix` (original text kept verbatim).
    public static func disablingMAMP(in text: String) -> (text: String, count: Int) {
        var count = 0
        let mapped = lines(text).map { line -> String in
            guard let kind = classify(String(line)), kind != .mixedPath else { return String(line) }
            count += 1
            return disabledPrefix + line
        }
        return (count == 0 ? text : mapped.joined(separator: "\n"), count)
    }

    /// Uncomments exactly the lines `disablingMAMP` commented out.
    public static func restoringMAMP(in text: String) -> (text: String, count: Int) {
        var count = 0
        let mapped = lines(text).map { line -> String in
            guard line.hasPrefix(disabledPrefix) else { return String(line) }
            count += 1
            return String(line.dropFirst(disabledPrefix.count))
        }
        return (count == 0 ? text : mapped.joined(separator: "\n"), count)
    }

    /// Kind of a MAMP-shadowing line, nil for anything else (comments, other MAMP references like `source`).
    static func classify(_ line: String) -> MAMPLine.Kind? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), t.contains(mampMarker) else { return nil }
        if let m = t.firstMatch(of: /^alias\s+(?:--\s+)?['"]?([A-Za-z0-9._-]+)['"]?\s*=/) {
            let name = String(m.1)
            let isPHPVersion = name.wholeMatch(of: /php[0-9.]+/) != nil
            return aliasNames.contains(name) || isPHPVersion ? .alias(name) : nil
        }
        if let m = t.firstMatch(of: /^(?:export\s+)?PATH\s*=\s*(.*)$/) {
            return pathKind(entries: String(m.1).split(separator: ":").map(String.init))
        }
        if let m = t.firstMatch(of: /^(?:typeset\s+-U\s+)?path\s*(?:\+)?=\s*\((.*)\)\s*$/) {
            return pathKind(entries: String(m.1).split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return nil
    }

    private static func pathKind(entries: [String]) -> MAMPLine.Kind {
        let cleaned = entries.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;")) }.filter { !$0.isEmpty }
        let onlyMAMP = cleaned.allSatisfy { e in
            e.contains(mampMarker) || e == "$PATH" || e == "${PATH}" || e == "$path" || e == "${path[@]}"
                || e == "$path[@]"
        }
        return onlyMAMP ? .path : .mixedPath
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func trimTrailingBlankLines(_ text: String) -> String {
        var ls = lines(text)
        while let last = ls.last, last.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeLast() }
        return ls.joined(separator: "\n")
    }

    // MARK: - Files

    /// Files scanned for MAMP lines.
    public var scannedFiles: [URL] {
        [".profile", ".zprofile", ".zshrc", ".bash_profile", ".bashrc"].map(file)
    }

    public func file(_ name: String) -> URL { home.appending(path: name, directoryHint: .notDirectory) }

    /// Files that get the PATH block: `~/.zprofile` + `~/.zshrc` (login + interactive non-login zsh, e.g. IDE
    /// terminals); `~/.bash_profile` when it exists (or bash is the login shell and neither it nor
    /// `~/.profile` exists — creating it would otherwise hide `~/.profile` from bash); `~/.profile` when it
    /// exists and sets PATH / aliases (or bash reads it for lack of `~/.bash_profile`).
    public func blockTargets(loginShell: String = ShellIntegration.loginShell()) -> [URL] {
        var targets = [file(".zprofile"), file(".zshrc")]
        let bashProfile = file(".bash_profile"), profile = file(".profile")
        let hasBashProfile = Self.exists(bashProfile), hasProfile = Self.exists(profile)
        let isBash = (loginShell as NSString).lastPathComponent == "bash"
        if hasBashProfile || (isBash && !hasProfile) { targets.append(bashProfile) }
        if hasProfile {
            let text = (try? Self.read(profile)) ?? ""
            let setsEnv = Self.containsBlock(text) || text.split(separator: "\n").contains { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#") && (t.contains("PATH=") || t.hasPrefix("alias "))
            }
            if setsEnv || (isBash && !hasBashProfile) { targets.append(profile) }
        }
        return targets
    }

    public struct FileStatus: Sendable, Equatable {
        public var file: URL
        public var exists: Bool
        public var hasBlock: Bool
    }

    public struct Status: Sendable, Equatable {
        public var shimDir: URL
        /// Managed shim names present in `~/.ramp/bin`.
        public var shims: [String]
        public var files: [FileStatus]
        /// Active MAMP lines (disableable or not), per file.
        public var conflicts: [MAMPLine]
        /// Lines RAMP disabled earlier (restorable).
        public var disabledLines: [MAMPLine]

        /// Every target file has the block.
        public var blockInstalled: Bool { !files.isEmpty && files.allSatisfy(\.hasBlock) }
        public var anyBlock: Bool { files.contains(where: \.hasBlock) }
        public var blockingConflicts: [MAMPLine] { conflicts.filter(\.disableable) }
    }

    public func status(loginShell: String = ShellIntegration.loginShell()) -> Status {
        let targets = blockTargets(loginShell: loginShell)
        var all = targets
        for f in scannedFiles where !all.contains(f) { all.append(f) }
        var files: [FileStatus] = []
        var conflicts: [MAMPLine] = []
        var disabled: [MAMPLine] = []
        for f in all {
            let text = (try? Self.read(f)) ?? ""
            if targets.contains(f) || Self.containsBlock(text) {
                files.append(FileStatus(file: f, exists: Self.exists(f), hasBlock: Self.containsBlock(text)))
            }
            conflicts += Self.mampConflicts(in: text).map { var l = $0; l.file = f; return l }
            disabled += Self.disabledMAMPLines(in: text).map { var l = $0; l.file = f; return l }
        }
        return Status(shimDir: shimDir, shims: CLIShimWriter(shimDir: shimDir).managedNames(), files: files,
                      conflicts: conflicts, disabledLines: disabled)
    }

    public struct ChangeReport: Sendable, Equatable {
        public var modified: [URL] = []
        public var backups: [URL] = []
        public var removedFiles: [URL] = []
        public var disabledMAMP = 0
        public var restoredMAMP = 0
    }

    /// Adds / refreshes the PATH block in every target; with `disableMAMP` also comments out the MAMP lines of
    /// every scanned file. Idempotent.
    @discardableResult
    public func install(disableMAMP: Bool, loginShell: String = ShellIntegration.loginShell(),
                        now: Date = Date()) throws -> ChangeReport {
        var report = ChangeReport()
        let targets = blockTargets(loginShell: loginShell)
        var all = targets
        for f in scannedFiles where !all.contains(f) { all.append(f) }
        for f in all {
            let original = Self.exists(f) ? try Self.read(f) : nil
            var text = original ?? ""
            if disableMAMP {
                let r = Self.disablingMAMP(in: text)
                text = r.text
                report.disabledMAMP += r.count
            }
            if targets.contains(f) { text = Self.insertingBlock(into: text) }
            guard text != (original ?? "") || (original == nil && targets.contains(f)) else { continue }
            try write(text, to: f, original: original, now: now, report: &report)
        }
        return report
    }

    /// Removes the PATH blocks; `restoreMAMP` also uncomments the lines RAMP disabled. A file that only held
    /// RAMP's block and has no backup (RAMP created it) is deleted.
    @discardableResult
    public func uninstall(restoreMAMP: Bool, now: Date = Date()) throws -> ChangeReport {
        var report = ChangeReport()
        var all = blockTargets()
        for f in scannedFiles where !all.contains(f) { all.append(f) }
        for f in all where Self.exists(f) {
            let original = try Self.read(f)
            var text = Self.removingBlock(from: original)
            if restoreMAMP {
                let r = Self.restoringMAMP(in: text)
                text = r.text
                report.restoredMAMP += r.count
            }
            guard text != original else { continue }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && backups(of: f).isEmpty {
                if unlink(ConfigText.path(Self.resolved(f))) == 0 { report.removedFiles.append(f) }
                continue
            }
            try write(text, to: f, original: original, now: now, report: &report)
        }
        return report
    }

    /// Uncomments the MAMP lines RAMP disabled (the PATH block stays).
    @discardableResult
    public func restoreMAMP(now: Date = Date()) throws -> ChangeReport {
        var report = ChangeReport()
        for f in scannedFiles where Self.exists(f) {
            let original = try Self.read(f)
            let r = Self.restoringMAMP(in: original)
            guard r.count > 0 else { continue }
            report.restoredMAMP += r.count
            try write(r.text, to: f, original: original, now: now, report: &report)
        }
        return report
    }

    /// Existing `<file>.ramp-backup-*` next to the (resolved) file.
    public func backups(of f: URL) -> [URL] {
        let target = Self.resolved(f)
        let dir = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + Self.backupInfix
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ConfigText.path(dir))) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { dir.appending(path: $0, directoryHint: .notDirectory) }
    }

    private func write(_ text: String, to f: URL, original: String?, now: Date, report: inout ChangeReport) throws {
        let target = Self.resolved(f)
        let fm = FileManager.default
        if original != nil, backups(of: f).isEmpty {
            let backup = target.deletingLastPathComponent()
                .appending(path: target.lastPathComponent + Self.backupInfix + Self.stamp(now), directoryHint: .notDirectory)
            try fm.copyItem(at: target, to: backup)
            report.backups.append(backup)
        }
        let path = ConfigText.path(target)
        var mode: mode_t = 0o644
        var st = stat()
        if stat(path, &st) == 0 { mode = st.st_mode & 0o7777 }
        let temp = ConfigText.path(target.deletingLastPathComponent()) + "/.\(target.lastPathComponent).ramp-tmp-\(UUID().uuidString)"
        guard fm.createFile(atPath: temp, contents: Data(text.utf8), attributes: [.posixPermissions: Int(mode)]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp])
        }
        chmod(temp, mode)
        if rename(temp, path) != 0 {
            let err = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        report.modified.append(f)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: ConfigText.path(url))
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: resolved(url), encoding: .utf8)
    }

    /// Symlinked dotfiles (dotfile repos) are edited at their target, the link stays.
    static func resolved(_ url: URL) -> URL {
        let path = ConfigText.path(url)
        guard let real = realpath(path, nil) else { return url }
        defer { free(real) }
        return URL(filePath: String(cString: real), directoryHint: .notDirectory)
    }

    /// The account's login shell (`pw_shell`), `/bin/zsh` when unknown.
    public static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    // MARK: - Probe

    /// What a NEW login shell resolves `command` to (`zsh -lic 'command -v php'`), run with this `home` as
    /// `HOME`, stdin /dev/null and a hard timeout. Returns the last output line (a path, or `alias php=…`), nil
    /// on timeout / nothing found.
    public func probe(command: String = "php", shell: String = ShellIntegration.loginShell(),
                      timeout: TimeInterval = 8) async -> String? {
        guard command.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else { return nil }
        let isBash = (shell as NSString).lastPathComponent == "bash"
        let exe = isBash ? "/bin/bash" : "/bin/zsh"
        let marker = "__RAMP_PROBE__"
        let argv = [exe, "-lic", "printf '\(marker)%s\\n' \"$(command -v \(command))\""]
        var env = ["HOME": ConfigText.path(home), "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
        guard let output = await Self.run(argv, environment: env, timeout: timeout) else { return nil }
        let line = output.split(separator: "\n").last { $0.hasPrefix(marker) }
        let value = line.map { String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
        return value?.isEmpty == false ? value : nil
    }

    /// `probe()` result points at this home's shim.
    public func resolvesToRAMP(_ probed: String?, command: String = "php") -> Bool {
        guard let probed else { return false }
        return probed == ConfigText.path(shimDir.appending(path: command, directoryHint: .notDirectory))
    }

    private static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval) async -> String? {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appending(path: "ramp-probe-\(UUID().uuidString).out", directoryHint: .notDirectory)
        guard fm.createFile(atPath: ConfigText.path(outURL), contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer { try? fm.removeItem(at: outURL) }
        let p = Process()
        p.executableURL = URL(filePath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        p.currentDirectoryURL = URL(filePath: environment["HOME"] ?? "/", directoryHint: .isDirectory)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        let finished: Bool = await withCheckedContinuation { c in
            let once = ResumeOnce(c)
            p.terminationHandler = { _ in once.resume(true) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                once.resume(false)
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume(false) { kill(pid, SIGKILL) }
            }
        }
        try? handle.close()
        guard finished else { return nil }
        return try? String(contentsOf: outURL, encoding: .utf8)
    }
}

/// Resumes a continuation exactly once (termination vs. timeout race).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }

    /// `true` when this call resumed it.
    @discardableResult
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}
