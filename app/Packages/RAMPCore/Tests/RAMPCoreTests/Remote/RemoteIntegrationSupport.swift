import Foundation
import Synchronization
import Testing
@testable import RAMPCore

/// Environment prepared by `Scripts/remote-it.sh` (throwaway sshd + pyftpdlib).
enum RemoteIT {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["RAMP_REMOTE_IT"] == "1" }
    static func value(_ key: String) -> String { env[key] ?? "" }
    static func port(_ key: String) -> Int { Int(env[key] ?? "") ?? 0 }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "ramp-remote-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func tempKnownHosts() throws -> KnownHosts {
        KnownHosts(fileURL: try tempDir().appending(path: "known_hosts.json"))
    }

    static func randomData(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// The protocol-independent round trip every backend must pass. `base` must exist and be
    /// writable; everything is created inside a fresh sub-folder and removed at the end.
    static func exerciseFileSystem(_ fs: any RemoteFileSystem, base: String) async throws {
        let root = RemotePath.join(base, "it-\(UUID().uuidString.prefix(8))")
        let spaced = RemotePath.join(root, "priečinok s medzerou ščťž")
        try await fs.createDirectory(root)
        try await fs.createDirectory(spaced)
        await #expect(throws: RemoteError.self) { try await fs.createDirectory(spaced) }

        // Upload: small file with a tricky name + a 6 MB file (chunked, several windows).
        let local = try tempDir()
        defer { try? FileManager.default.removeItem(at: local) }
        let small = Data("Ahoj ščťžýáíé #;?%\n".utf8)
        let big = randomData(6 * 1024 * 1024 + 123)
        try small.write(to: local.appending(path: "small.txt"))
        try big.write(to: local.appending(path: "big.bin"))
        let smallRemote = RemotePath.join(spaced, "súbor ščťž #1;x.txt")
        let bigRemote = RemotePath.join(root, "big.bin")
        try await fs.upload(local.appending(path: "small.txt"), to: smallRemote, progress: nil)
        let upProgress = Mutex<(Int64, Int64?)>((0, nil))
        try await fs.upload(local.appending(path: "big.bin"), to: bigRemote) { done, total in
            upProgress.withLock { $0 = (done, total) }
        }
        #expect(upProgress.withLock { $0.0 } == Int64(big.count))

        // List + stat.
        let listing = try await fs.list(root)
        #expect(Set(listing.map(\.name)) == ["priečinok s medzerou ščťž", "big.bin"])
        let bigItem = try #require(listing.first { $0.name == "big.bin" })
        #expect(bigItem.kind == .file && bigItem.size == Int64(big.count) && bigItem.path == bigRemote)
        #expect(listing.first { $0.kind == .directory }?.path == spaced)
        let inner = try await fs.list(spaced)
        #expect(inner.map(\.name) == ["súbor ščťž #1;x.txt"])
        #expect(inner.first?.size == Int64(small.count))
        #expect(try await fs.stat(smallRemote)?.kind == .file)
        #expect(try await fs.stat(spaced)?.kind == .directory)
        #expect(try await fs.stat(RemotePath.join(root, "missing")) == nil)

        // Download + compare bytes.
        let dlProgress = Mutex<Int64>(0)
        try await fs.download(bigRemote, to: local.appending(path: "big-back.bin")) { done, _ in
            dlProgress.withLock { $0 = done }
        }
        #expect(try Data(contentsOf: local.appending(path: "big-back.bin")) == big)
        #expect(dlProgress.withLock { $0 } == Int64(big.count))
        try await fs.download(smallRemote, to: local.appending(path: "small-back.txt"), progress: nil)
        #expect(try Data(contentsOf: local.appending(path: "small-back.txt")) == small)
        // Overwrite on download.
        try await fs.download(smallRemote, to: local.appending(path: "big-back.bin"), progress: nil)
        #expect(try Data(contentsOf: local.appending(path: "big-back.bin")) == small)

        // Errors.
        await #expect(throws: RemoteError.notFound(RemotePath.join(root, "nope.txt"))) {
            try await fs.download(RemotePath.join(root, "nope.txt"), to: local.appending(path: "x"), progress: nil)
        }
        await #expect(throws: RemoteError.self) { try await fs.list(RemotePath.join(root, "nope")) }

        // Rename.
        let renamed = RemotePath.join(root, "renamed big.bin")
        try await fs.rename(bigRemote, to: renamed)
        #expect(try await fs.stat(bigRemote) == nil)
        #expect(try await fs.stat(renamed)?.size == Int64(big.count))

        // Tree helpers: upload a local folder, download it back, delete everything.
        let tree = local.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "a b/c"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: tree.appending(path: "one.txt"))
        try Data("22".utf8).write(to: tree.appending(path: "a b/c/two ž.txt"))
        let last = Mutex<TransferProgress?>(nil)
        try await RemoteTransfers.uploadTree(fs, localURL: tree, intoRemoteDir: root, conflict: .overwrite) { p in
            last.withLock { $0 = p }
        }
        #expect(last.withLock { $0?.filesDone } == 2)
        #expect(try await RemoteTransfers.conflicts(uploading: [tree], intoRemoteDir: root, fs: fs) == ["tree"])
        let back = local.appending(path: "back")
        let treeItem = try #require(try await fs.stat(RemotePath.join(root, "tree")))
        try await RemoteTransfers.downloadTree(fs, item: treeItem, into: back, conflict: .overwrite) { _ in }
        #expect(try String(contentsOf: back.appending(path: "tree/a b/c/two ž.txt"), encoding: .utf8) == "22")

        // Cancel a download mid-file: CancellationError, destination untouched.
        let cancelTarget = local.appending(path: "cancelled.bin")
        let holder = Mutex<Task<Void, Error>?>(nil)
        let task = Task {
            try await fs.download(renamed, to: cancelTarget) { done, _ in
                guard done > 0 else { return }
                while holder.withLock({ $0 == nil }) { usleep(1000) }
                holder.withLock { $0?.cancel() }
            }
        }
        holder.withLock { $0 = task }
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("cancelled download finished")
            return
        }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: cancelTarget.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.path(percentEncoded: false))
            .allSatisfy { !$0.hasSuffix(".part") })
        // Session still usable after a cancel.
        #expect(try await fs.stat(renamed) != nil)

        let rootItem = try #require(try await fs.stat(root))
        try await RemoteTransfers.deleteTree(fs, item: rootItem)
        #expect(try await fs.stat(root) == nil)
    }
}
