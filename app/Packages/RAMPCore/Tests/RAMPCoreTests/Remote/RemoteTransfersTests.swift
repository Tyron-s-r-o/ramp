import Foundation
import Synchronization
import Testing
@testable import RAMPCore

/// In-memory `RemoteFileSystem`: paths → nodes; records mutating operations in order.
final class FakeRemoteFS: RemoteFileSystem {
    enum Node: Equatable { case file(Data), dir, link }
    struct State {
        var nodes: [String: Node] = ["/": .dir]
        var ops: [String] = []
    }
    let state = Mutex(State())
    /// Called before each download/upload chunk (lets a test cancel mid-transfer).
    let chunkHook: (@Sendable (String) -> Void)?

    init(_ nodes: [String: Node] = [:], chunkHook: (@Sendable (String) -> Void)? = nil) {
        self.chunkHook = chunkHook
        state.withLock { s in for (k, v) in nodes { s.nodes[k] = v } }
    }

    var ops: [String] { state.withLock { $0.ops } }
    func node(_ p: String) -> Node? { state.withLock { $0.nodes[p] } }

    private func item(_ path: String, _ node: Node) -> RemoteItem {
        switch node {
        case .file(let d): RemoteItem(path: path, name: RemotePath.name(path), kind: .file, size: Int64(d.count))
        case .dir: RemoteItem(path: path, name: RemotePath.name(path), kind: .directory)
        case .link: RemoteItem(path: path, name: RemotePath.name(path), kind: .symlink)
        }
    }

    func homeDirectory() async throws -> String { "/" }

    func list(_ path: String) async throws -> [RemoteItem] {
        try state.withLock { s in
            guard s.nodes[path] == .dir else { throw RemoteError.notFound(path) }
            return s.nodes.filter { $0.key != "/" && RemotePath.parent($0.key) == path && $0.key != path }
                .map { item($0.key, $0.value) }.sorted { $0.name < $1.name }
        }
    }

    func stat(_ path: String) async throws -> RemoteItem? {
        state.withLock { s in s.nodes[path].map { item(path, $0) } }
    }

    func download(_ remotePath: String, to localURL: URL, progress: RemoteProgress?) async throws {
        guard case .file(let data) = node(remotePath) else { throw RemoteError.notFound(remotePath) }
        var out = Data()
        for chunk in stride(from: 0, to: max(data.count, 1), by: 4) {
            chunkHook?(remotePath)
            try Task.checkCancellation()
            out.append(data[chunk..<min(chunk + 4, data.count)])
            progress?(Int64(out.count), Int64(data.count))
        }
        try out.write(to: localURL)
        state.withLock { $0.ops.append("get \(remotePath)") }
    }

    func upload(_ localURL: URL, to remotePath: String, progress: RemoteProgress?) async throws {
        let data = try Data(contentsOf: localURL)
        try state.withLock { s in
            guard s.nodes[RemotePath.parent(remotePath)] == .dir else { throw RemoteError.notFound(remotePath) }
        }
        chunkHook?(remotePath)
        try Task.checkCancellation()
        progress?(Int64(data.count), Int64(data.count))
        state.withLock { s in
            s.nodes[remotePath] = .file(data)
            s.ops.append("put \(remotePath)")
        }
    }

    func createDirectory(_ path: String) async throws {
        try state.withLock { s in
            guard s.nodes[path] == nil else { throw RemoteError.alreadyExists(path) }
            guard s.nodes[RemotePath.parent(path)] == .dir else { throw RemoteError.notFound(path) }
            s.nodes[path] = .dir
            s.ops.append("mkdir \(path)")
        }
    }

    func rename(_ from: String, to: String) async throws {
        state.withLock { s in
            s.nodes[to] = s.nodes.removeValue(forKey: from)
            s.ops.append("mv \(from) \(to)")
        }
    }

    func delete(_ item: RemoteItem) async throws {
        try state.withLock { s in
            if item.kind == .directory, s.nodes.keys.contains(where: { RemotePath.parent($0) == item.path && $0 != item.path }) {
                throw RemoteError.permissionDenied("not empty: \(item.path)")
            }
            guard s.nodes.removeValue(forKey: item.path) != nil else { throw RemoteError.notFound(item.path) }
            s.ops.append("rm \(item.path)")
        }
    }

    func close() async {}
}

/// Thread-safe recorder of progress snapshots.
final class ProgressLog: Sendable {
    private let items = Mutex<[TransferProgress]>([])
    func record(_ p: TransferProgress) { items.withLock { $0.append(p) } }
    var all: [TransferProgress] { items.withLock { $0 } }
}

struct RemoteTransfersTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "ramp-xfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sampleTree() -> FakeRemoteFS {
        FakeRemoteFS([
            "/site": .dir,
            "/site/index.php": .file(Data("<?php echo 1;".utf8)),
            "/site/assets": .dir,
            "/site/assets/app.css": .file(Data("body{}".utf8)),
            "/site/assets/empty": .dir,
            "/site/current": .link,
        ])
    }

    @Test func downloadTreeRecursesSkipsSymlinksAndReportsTotals() async throws {
        let fs = sampleTree()
        let local = try tempDir()
        defer { try? FileManager.default.removeItem(at: local) }
        let log = ProgressLog()
        let root = try #require(try await fs.stat("/site"))

        try await RemoteTransfers.downloadTree(fs, item: root, into: local, conflict: .overwrite, progress: log.record)

        #expect(try String(contentsOf: local.appending(path: "site/index.php"), encoding: .utf8) == "<?php echo 1;")
        #expect(try String(contentsOf: local.appending(path: "site/assets/app.css"), encoding: .utf8) == "body{}")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: local.appending(path: "site/assets/empty").path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue)
        #expect(!FileManager.default.fileExists(atPath: local.appending(path: "site/current").path(percentEncoded: false)))

        let last = try #require(log.all.last)
        #expect(last.filesTotal == 2 && last.filesDone == 2)
        #expect(last.bytesTotal == 19 && last.bytesDone == 19)
        #expect(log.all.allSatisfy { $0.bytesDone <= 19 })
        // Monotonic byte counter.
        #expect(zip(log.all, log.all.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
    }

    @Test func downloadSkipKeepsExistingLocalFile() async throws {
        let fs = sampleTree()
        let local = try tempDir()
        defer { try? FileManager.default.removeItem(at: local) }
        try FileManager.default.createDirectory(at: local.appending(path: "site"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: local.appending(path: "site/index.php"))
        let root = try #require(try await fs.stat("/site"))
        #expect(RemoteTransfers.conflicts(downloading: [root], into: local) == ["site"])

        try await RemoteTransfers.downloadTree(fs, item: root, into: local, conflict: .skip) { _ in }
        #expect(try String(contentsOf: local.appending(path: "site/index.php"), encoding: .utf8) == "mine")
        #expect(fs.ops == ["get /site/assets/app.css"])

        try await RemoteTransfers.downloadTree(fs, item: root, into: local, conflict: .overwrite) { _ in }
        #expect(try String(contentsOf: local.appending(path: "site/index.php"), encoding: .utf8) == "<?php echo 1;")
    }

    private func localTree() throws -> URL {
        let d = try tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: d.appending(path: "proj/src/deep"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: d.appending(path: "proj/a.txt"))
        try Data("bb".utf8).write(to: d.appending(path: "proj/src/b.txt"))
        try Data("ccc".utf8).write(to: d.appending(path: "proj/src/deep/c ščťž.txt"))
        return d
    }

    @Test func uploadTreeCreatesFoldersAndFiles() async throws {
        let fs = FakeRemoteFS(["/www": .dir])
        let local = try localTree()
        defer { try? FileManager.default.removeItem(at: local) }
        let log = ProgressLog()

        try await RemoteTransfers.uploadTree(fs, localURL: local.appending(path: "proj"), intoRemoteDir: "/www",
                                             conflict: .overwrite, progress: log.record)
        #expect(fs.ops == ["mkdir /www/proj", "put /www/proj/a.txt", "mkdir /www/proj/src",
                           "put /www/proj/src/b.txt", "mkdir /www/proj/src/deep", "put /www/proj/src/deep/c ščťž.txt"])
        #expect(fs.node("/www/proj/src/deep/c ščťž.txt") == .file(Data("ccc".utf8)))
        let last = try #require(log.all.last)
        #expect(last.filesDone == 3 && last.filesTotal == 3 && last.bytesDone == 6 && last.bytesTotal == 6)
    }

    @Test func uploadMergesExistingFoldersAndHonoursSkip() async throws {
        let fs = FakeRemoteFS(["/www": .dir, "/www/proj": .dir, "/www/proj/a.txt": .file(Data("old".utf8))])
        let local = try localTree()
        defer { try? FileManager.default.removeItem(at: local) }

        #expect(try await RemoteTransfers.conflicts(uploading: [local.appending(path: "proj"), local.appending(path: "x")],
                                                    intoRemoteDir: "/www", fs: fs) == ["proj"])
        #expect(try await RemoteTransfers.conflicts(uploading: [local.appending(path: "proj")],
                                                    intoRemoteDir: "/missing", fs: fs).isEmpty)

        try await RemoteTransfers.uploadTree(fs, localURL: local.appending(path: "proj"), intoRemoteDir: "/www",
                                             conflict: .skip) { _ in }
        #expect(fs.node("/www/proj/a.txt") == .file(Data("old".utf8)))
        #expect(!fs.ops.contains("mkdir /www/proj"))
        #expect(fs.ops.contains("put /www/proj/src/b.txt"))

        try await RemoteTransfers.uploadTree(fs, localURL: local.appending(path: "proj/a.txt"), intoRemoteDir: "/www/proj",
                                             conflict: .overwrite) { _ in }
        #expect(fs.node("/www/proj/a.txt") == .file(Data("a".utf8)))
    }

    @Test func uploadFileOverRemoteFolderFails() async throws {
        let fs = FakeRemoteFS(["/www": .dir, "/www/a.txt": .dir])
        let local = try localTree()
        defer { try? FileManager.default.removeItem(at: local) }
        await #expect(throws: RemoteError.alreadyExists("/www/a.txt")) {
            try await RemoteTransfers.uploadTree(fs, localURL: local.appending(path: "proj/a.txt"), intoRemoteDir: "/www",
                                                 conflict: .overwrite) { _ in }
        }
    }

    @Test func deleteTreeIsDepthFirst() async throws {
        let fs = sampleTree()
        let root = try #require(try await fs.stat("/site"))
        try await RemoteTransfers.deleteTree(fs, item: root)
        #expect(fs.ops == ["rm /site/assets/app.css", "rm /site/assets/empty", "rm /site/assets",
                           "rm /site/current", "rm /site/index.php", "rm /site"])
        #expect(fs.node("/site") == nil)
    }

    @Test func cancellationStopsBatch() async throws {
        let counter = Mutex(0)
        let started = AsyncStream<Void>.makeStream()
        let fs = FakeRemoteFS((0..<20).reduce(into: ["/d": .dir]) { $0["/d/f\($1)"] = .file(Data(repeating: 1, count: 16)) },
                              chunkHook: { _ in
                                  let n = counter.withLock { $0 += 1; return $0 }
                                  if n == 6 { started.continuation.yield() }
                                  if n > 5 { Thread.sleep(forTimeInterval: 0.01) }
                              })
        let local = try tempDir()
        defer { try? FileManager.default.removeItem(at: local) }
        let root = try #require(try await fs.stat("/d"))
        let task = Task {
            try await RemoteTransfers.downloadTree(fs, item: root, into: local, conflict: .overwrite) { _ in }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fs.ops.count < 20)
    }
}
