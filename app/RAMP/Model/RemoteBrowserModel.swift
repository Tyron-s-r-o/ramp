import AppKit
import Foundation
import Observation
import Synchronization
import RAMPCore

/// One queued / running / finished transfer (upload, download or recursive delete) of the browser.
@MainActor @Observable
final class RemoteTransferJob: Identifiable {
    enum Kind: Equatable { case upload, download, delete }
    enum Status: Equatable {
        case queued, running, done, cancelled
        case failed(String)
    }
    typealias Work = @Sendable (any RemoteFileSystem, @escaping RemoteTransfers.Progress) async throws -> Void

    let id = UUID()
    let kind: Kind
    let title: String
    /// Destination shown under the title (local folder / remote folder).
    let destination: String
    var status: Status = .queued
    var progress: TransferProgress?
    /// Remote folder to re-list when the job ends (uploads / deletes into the visible folder).
    @ObservationIgnored var refreshDir: String?
    @ObservationIgnored let work: Work
    @ObservationIgnored var task: Task<Void, any Error>?
    @ObservationIgnored var cancelRequested = false
    @ObservationIgnored var onFinish: ((Error?) -> Void)?

    init(kind: Kind, title: String, destination: String, work: @escaping Work) {
        self.kind = kind
        self.title = title
        self.destination = destination
        self.work = work
    }

    var isActive: Bool { status == .queued || status == .running }
}

/// Coalesces progress callbacks (any thread, many per second) into ≤ 10 main-actor updates per second.
final class ProgressThrottle: Sendable {
    private struct State {
        var latest: TransferProgress?
        var scheduled = false
    }
    private let state = Mutex(State())
    private let apply: @MainActor @Sendable (TransferProgress) -> Void

    init(apply: @escaping @MainActor @Sendable (TransferProgress) -> Void) {
        self.apply = apply
    }

    var callback: RemoteTransfers.Progress {
        { [self] progress in report(progress) }
    }

    private func report(_ progress: TransferProgress) {
        let schedule = state.withLock { s -> Bool in
            s.latest = progress
            if s.scheduled { return false }
            s.scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.flush()
        }
    }

    @MainActor func flush() {
        let latest = state.withLock { s -> TransferProgress? in
            s.scheduled = false
            return s.latest
        }
        if let latest { apply(latest) }
    }
}

/// Upload waiting for the conflict decision (Prepísať / Preskočiť existujúce / Zrušiť).
struct PendingUpload: Identifiable {
    let id = UUID()
    var urls: [URL]
    var remoteDir: String
    var conflicts: [String]
}

/// Download ("Stiahnuť…") waiting for the conflict decision.
struct PendingDownload: Identifiable {
    let id = UUID()
    var items: [RemoteItem]
    var localDir: URL
    var conflicts: [String]
}

/// Browser of one connected site. Listing / rename / mkdir use the browsing session; uploads, downloads and
/// recursive deletes run one by one on a SEPARATE transfer session so browsing stays responsive (FTP
/// serializes one operation per control connection).
@MainActor @Observable
final class RemoteBrowserModel {
    enum State: Equatable {
        case preparing, connecting, connected
        case failed(String)
    }

    let site: RemoteSite
    @ObservationIgnored var secrets: SiteSecrets?
    @ObservationIgnored let knownHosts: KnownHosts
    @ObservationIgnored weak var owner: RemoteModel?

    private(set) var state: State = .preparing
    /// Last connection error was a rejected login (offer "Zadať heslo…").
    private(set) var authFailed = false
    private(set) var path = ""
    private(set) var items: [RemoteItem] = []
    private(set) var loading = false
    /// Inline error of the last listing / operation.
    var error: String?
    private(set) var jobs: [RemoteTransferJob] = []
    var transfersExpanded = true
    var pendingUpload: PendingUpload?
    var pendingDownload: PendingDownload?

    @ObservationIgnored private var fs: (any RemoteFileSystem)?
    @ObservationIgnored private var transferFS: (any RemoteFileSystem)?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var closed = false

    init(site: RemoteSite, knownHosts: KnownHosts) {
        self.site = site
        self.knownHosts = knownHosts
    }

    var hasActiveJobs: Bool { jobs.contains { $0.isActive } }
    var activeJobCount: Int { jobs.filter(\.isActive).count }
    var isConnecting: Bool { state == .preparing || state == .connecting }

    // MARK: Connection

    func connect() async {
        #if DEBUG
        if ScreenshotMode.isRendering { return }
        #endif
        closed = false
        authFailed = false
        state = .connecting
        let old = fs
        fs = nil
        if let old { await old.close() }
        do {
            let session = try await RemoteConnector.connect(site: site, secrets: secrets, knownHosts: knownHosts)
            guard !closed else { await session.close(); return }
            fs = session
            state = .connected
            let home: String
            do {
                home = try await session.homeDirectory()
            } catch {
                self.error = RemoteModel.describe(error)
                home = "/"
            }
            await load(home)
        } catch let remote as RemoteError {
            guard !closed else { return }
            state = .failed(RemoteModel.describe(remote))
            switch remote {
            case .unknownHostKey, .hostKeyMismatch:
                owner?.handleHostKey(remote, for: self)
            case .missingSecret:
                if let owner {
                    let field: SecretPrompt.Field = site.auth == .privateKey ? .passphrase : .password
                    Task { await owner.retryWithNewSecret(self, field: field) }
                }
            case .authenticationFailed:
                authFailed = true
            default:
                break
            }
        } catch {
            guard !closed else { return }
            state = .failed(RemoteModel.describe(error))
        }
    }

    func disconnect() {
        closed = true
        for job in jobs where job.isActive { cancel(job) }
        let sessions = [fs, transferFS].compactMap { $0 }
        fs = nil
        transferFS = nil
        Task.detached {
            for session in sessions { await session.close() }
        }
    }

    // MARK: Listing

    func open(_ target: String) {
        Task { await load(target) }
    }

    func refresh() { open(path) }

    func goUp() {
        guard path != "/", !path.isEmpty else { return }
        open(RemotePath.parent(path))
    }

    func load(_ target: String) async {
        guard let fs else { return }
        let normalized = Self.normalize(target)
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        do {
            let list = try await fs.list(normalized)
            guard generation == loadGeneration, !closed else { return }
            items = list.filter { $0.name != "." && $0.name != ".." }
            path = normalized
            error = nil
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration else { return }
            self.error = RemoteModel.describe(error)
        }
    }

    /// Breadcrumb segments: ("/", "/"), ("var", "/var"), ("www", "/var/www").
    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Simple operations (browsing session)

    static func nameProblem(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "." || n == ".." || n.contains("/")
    }

    func rename(_ item: RemoteItem, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard let fs, !Self.nameProblem(name), name != item.name else { return }
        do {
            try await fs.rename(item.path, to: RemotePath.join(RemotePath.parent(item.path), name))
            await load(path)
        } catch {
            self.error = RemoteModel.describe(error)
        }
    }

    func createFolder(named newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard let fs, !Self.nameProblem(name) else { return }
        do {
            try await fs.createDirectory(RemotePath.join(path, name))
            await load(path)
        } catch {
            self.error = RemoteModel.describe(error)
        }
    }

    func copyPaths(_ items: [RemoteItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Transfers

    /// Drop from Finder: checks conflicts once, then asks or enqueues.
    func requestUpload(_ urls: [URL], into remoteDir: String) async {
        guard !urls.isEmpty, let fs else { return }
        let conflicts: [String]
        do {
            conflicts = try await RemoteTransfers.conflicts(uploading: urls, intoRemoteDir: remoteDir, fs: fs)
        } catch {
            self.error = RemoteModel.describe(error)
            return
        }
        if conflicts.isEmpty {
            enqueueUpload(urls, into: remoteDir, conflict: .overwrite)
        } else {
            pendingUpload = PendingUpload(urls: urls, remoteDir: remoteDir, conflicts: conflicts)
        }
    }

    func enqueueUpload(_ urls: [URL], into remoteDir: String, conflict: ConflictPolicy) {
        let title = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) položiek")
        let job = RemoteTransferJob(kind: .upload, title: title, destination: remoteDir) { fs, progress in
            try await RemoteTransfers.upload(fs, localURLs: urls, intoRemoteDir: remoteDir, conflict: conflict,
                                             progress: progress)
        }
        job.refreshDir = remoteDir
        enqueue(job)
    }

    /// "Stiahnuť…" after the folder was chosen.
    func requestDownload(_ items: [RemoteItem], into localDir: URL) {
        let downloadable = items.filter { $0.kind != .symlink }
        guard !downloadable.isEmpty else { return }
        let conflicts = RemoteTransfers.conflicts(downloading: downloadable, into: localDir)
        if conflicts.isEmpty {
            enqueueDownload(downloadable, into: localDir, conflict: .overwrite)
        } else {
            pendingDownload = PendingDownload(items: downloadable, localDir: localDir, conflicts: conflicts)
        }
    }

    func enqueueDownload(_ items: [RemoteItem], into localDir: URL, conflict: ConflictPolicy) {
        let title = items.count == 1 ? items[0].name : String(localized: "\(items.count) položiek")
        let job = RemoteTransferJob(kind: .download, title: title, destination: localDir.path(percentEncoded: false)) { fs, progress in
            try await RemoteTransfers.download(fs, items: items, into: localDir, conflict: conflict, progress: progress)
        }
        enqueue(job)
    }

    /// Drag to Finder (file promise): downloads into a temporary folder on the destination volume, then moves
    /// the file / folder to `destination` (a free name when something with that name already exists there).
    func promiseDownload(_ item: RemoteItem, to destination: URL, completion: @escaping @Sendable (Error?) -> Void) {
        guard state == .connected else {
            completion(RemoteError.connectionFailed(String(localized: "Pripojenie bolo ukončené.")))
            return
        }
        let job = RemoteTransferJob(kind: .download, title: item.name,
                                    destination: destination.deletingLastPathComponent().path(percentEncoded: false)) { fs, progress in
            let fm = FileManager.default
            let temp = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination.deletingLastPathComponent(), create: true))
                ?? fm.temporaryDirectory.appending(path: "RAMP-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fm.removeItem(at: temp) }
            try await RemoteTransfers.download(fs, items: [item], into: temp, conflict: .overwrite, progress: progress)
            try fm.moveItem(at: temp.appending(path: item.name), to: Self.freeURL(destination))
        }
        job.onFinish = { error in completion(error) }
        enqueue(job)
    }

    func enqueueDelete(_ items: [RemoteItem]) {
        let title = items.count == 1 ? items[0].name : String(localized: "\(items.count) položiek")
        let job = RemoteTransferJob(kind: .delete, title: title, destination: path) { fs, _ in
            for item in items { try await RemoteTransfers.deleteTree(fs, item: item) }
        }
        job.refreshDir = path
        enqueue(job)
    }

    func cancel(_ job: RemoteTransferJob) {
        switch job.status {
        case .queued:
            job.status = .cancelled
            finish(job, error: CancellationError())
        case .running:
            job.cancelRequested = true
            job.task?.cancel()
        default:
            break
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func enqueue(_ job: RemoteTransferJob) {
        jobs.append(job)
        transfersExpanded = true
        pump()
    }

    private func pump() {
        guard runner == nil, !closed, let job = jobs.first(where: { $0.status == .queued }) else { return }
        runner = Task { [weak self] in
            await self?.run(job)
            self?.runner = nil
            self?.pump()
        }
    }

    private func run(_ job: RemoteTransferJob) async {
        job.status = .running
        do {
            let session = try await transferSession()
            if job.cancelRequested { throw CancellationError() }
            let throttle = ProgressThrottle { [weak job] progress in job?.progress = progress }
            let work = job.work
            let callback = throttle.callback
            let task = Task.detached(priority: .userInitiated) { try await work(session, callback) }
            job.task = task
            try await task.value
            throttle.flush()
            job.status = .done
            finish(job, error: nil)
        } catch {
            // A cancelled or failed transfer may leave the session mid-command → start a fresh one next time.
            dropTransferSession()
            if error is CancellationError || job.cancelRequested {
                job.status = .cancelled
                finish(job, error: CancellationError())
            } else {
                job.status = .failed(RemoteModel.describe(error))
                finish(job, error: error)
            }
        }
    }

    private func finish(_ job: RemoteTransferJob, error: Error?) {
        let onFinish = job.onFinish
        job.onFinish = nil
        onFinish?(error)
        if let dir = job.refreshDir, dir == path, state == .connected, !closed { refresh() }
    }

    private func transferSession() async throws -> any RemoteFileSystem {
        if let transferFS { return transferFS }
        let session = try await RemoteConnector.connect(site: site, secrets: secrets, knownHosts: knownHosts)
        if closed {
            await session.close()
            throw CancellationError()
        }
        transferFS = session
        return session
    }

    private func dropTransferSession() {
        guard let session = transferFS else { return }
        transferFS = nil
        Task.detached { await session.close() }
    }

    /// `destination`, or "name 2.ext", "name 3.ext"… when it already exists (never overwrite on a drag).
    nonisolated static func freeURL(_ destination: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path(percentEncoded: false)) else { return destination }
        let dir = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let base = ext.isEmpty ? destination.lastPathComponent : destination.deletingPathExtension().lastPathComponent
        for n in 2...9_999 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appending(path: name)
            if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return dir.appending(path: "\(base) \(UUID().uuidString)")
    }

    // MARK: Demo (screenshots)

    #if DEBUG
    func loadDemo() {
        state = .connected
        path = DemoData.remotePath
        items = DemoData.remoteItems
        let upload = RemoteTransferJob(kind: .upload, title: "dist", destination: DemoData.remotePath) { _, _ in }
        upload.status = .running
        upload.progress = TransferProgress(currentPath: "dist/assets/app.js", bytesDone: 3_407_872,
                                           bytesTotal: 8_912_896, filesDone: 14, filesTotal: 37)
        let download = RemoteTransferJob(kind: .download, title: "backup-2026-09-24.sql.gz",
                                         destination: "~/Downloads") { _, _ in }
        download.status = .done
        download.progress = TransferProgress(currentPath: "", bytesDone: 48_234_496, bytesTotal: 48_234_496,
                                             filesDone: 1, filesTotal: 1)
        jobs = [download, upload]
    }
    #endif
}
