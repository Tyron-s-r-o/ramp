import Citadel
import Foundation
import Logging
import NIOCore
import NIOSSH
import Synchronization

/// SFTP session over Citadel (SwiftNIO SSH). One SSH connection + one SFTP channel per instance.
/// Transfers are streamed in chunks with a small window of requests in flight; Task
/// cancellation aborts between chunks.
public final class SFTPFileSystem: RemoteFileSystem {
    private let ssh: SSHBox
    private let sftp: SFTPClient
    private let initialPath: String?

    /// Read / write request size and how many requests may be in flight at once.
    static let readChunk: UInt32 = 64 * 1024
    static let writeChunk = 32_000 // swift-nio-ssh limit per channel message (Citadel slices at this size too)
    static let window = 16

    /// Citadel logs every request (with full paths) at `.info`; keep only problems.
    private static let logger: Logger = {
        var l = Logger(label: "sk.tyron.ramp.sftp")
        l.logLevel = .warning
        return l
    }()

    private init(ssh: SSHClient, sftp: SFTPClient, initialPath: String?) {
        self.ssh = SSHBox(client: ssh)
        self.sftp = sftp
        self.initialPath = initialPath
    }

    /// Connects, validates the host key against `knownHosts` and authenticates.
    /// - Throws: `RemoteError.unknownHostKey` / `.hostKeyMismatch` / `.authenticationFailed` / …
    public static func connect(site: RemoteSite, secrets: SiteSecrets?, knownHosts: KnownHosts) async throws -> SFTPFileSystem {
        let auths: [SSHAuthenticationMethod]
        switch site.auth {
        case .password:
            guard let password = secrets?.password else { throw RemoteError.missingSecret }
            auths = [.passwordBased(username: site.username, password: password)]
        case .privateKey:
            guard let path = site.privateKeyPath, !path.isEmpty else {
                throw RemoteError.protocolError("Pre prihlásenie kľúčom chýba cesta ku kľúču.")
            }
            auths = try SFTPKeyLoader.authentications(username: site.username, keyPath: path,
                                                      passphrase: secrets?.keyPassphrase)
        }

        // RSA keys yield several signature algorithms (rsa-sha2-512, -256, ssh-rsa). Citadel offers
        // one per connection, so a rejected one means a fresh connection with the next.
        let validator = HostKeyValidator(host: site.host, port: site.port, knownHosts: knownHosts)
        var client: SSHClient?
        for (index, auth) in auths.enumerated() {
            do {
                client = try await SSHClient.connect(
                    host: site.host, port: site.port,
                    authenticationMethod: auth,
                    hostKeyValidator: .custom(validator),
                    reconnect: .never,
                    algorithms: .all,
                    connectTimeout: .seconds(20))
                break
            } catch {
                if let rejected = validator.rejection { throw rejected }
                let mapped = mapError(error, path: nil)
                guard case RemoteError.authenticationFailed = mapped, index < auths.count - 1 else { throw mapped }
            }
        }
        guard let client else { throw RemoteError.authenticationFailed }
        do {
            let sftp = try await client.openSFTP(logger: Self.logger)
            let initial = site.initialPath.flatMap { $0.isEmpty ? nil : $0 }
            return SFTPFileSystem(ssh: client, sftp: sftp, initialPath: initial)
        } catch {
            try? await client.close()
            throw mapError(error, path: nil)
        }
    }

    // MARK: RemoteFileSystem

    public func homeDirectory() async throws -> String {
        if let initialPath {
            return initialPath.hasPrefix("/") ? initialPath : try await call(initialPath) { try await sftp.getRealPath(atPath: initialPath) }
        }
        return try await call(nil) { try await sftp.getRealPath(atPath: ".") }
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let names = try await call(path) { try await sftp.listDirectory(atPath: path) }
        return names.flatMap(\.components).compactMap { c in
            guard c.filename != ".", c.filename != ".." else { return nil }
            return Self.item(path: RemotePath.join(path, c.filename), name: c.filename,
                             attributes: c.attributes, longname: c.longname)
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        do {
            let attrs = try await call(path) { try await sftp.getAttributes(at: path) }
            return Self.item(path: path, name: RemotePath.name(path), attributes: attrs, longname: nil)
        } catch RemoteError.notFound {
            return nil
        }
    }

    public func download(_ remotePath: String, to localURL: URL, progress: RemoteProgress?) async throws {
        let file = try await call(remotePath) { try await sftp.openFile(filePath: remotePath, flags: .read) }
        let box = FileBox(file: file)
        let tmp = localURL.deletingLastPathComponent().appending(path: ".\(localURL.lastPathComponent).ramp-\(UUID().uuidString).part")
        do {
            let size = try? await file.readAttributes().size
            guard FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: nil) else {
                throw RemoteError.permissionDenied(localURL.path(percentEncoded: false))
            }
            let out = try FileHandle(forWritingTo: tmp)
            defer { try? out.close() }
            try await call(remotePath) {
                try await Self.pipelinedRead(box, size: size.map { Int64($0) }, out: out, progress: progress)
            }
            try out.synchronize()
            try? await file.close()
            _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tmp)
        } catch {
            try? await file.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, progress: RemoteProgress?) async throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: localURL) } catch {
            throw RemoteError.notFound(localURL.path(percentEncoded: false))
        }
        defer { try? input.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
        let file = try await call(remotePath) {
            try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        }
        let box = FileBox(file: file)
        do {
            try await call(remotePath) {
                try await Self.pipelinedWrite(box, input: input, total: total, progress: progress)
            }
            try await call(remotePath) { try await file.close() }
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func createDirectory(_ path: String) async throws {
        do {
            try await call(path) { try await sftp.createDirectory(atPath: path) }
        } catch let error as RemoteError {
            // SFTP v3 reports "exists" as a generic failure — check.
            if case .protocolError = error, (try? await stat(path)) != nil { throw RemoteError.alreadyExists(path) }
            throw error
        }
    }

    public func rename(_ from: String, to: String) async throws {
        do {
            try await call(from) { try await sftp.rename(at: from, to: to) }
        } catch let error as RemoteError {
            if case .protocolError = error, (try? await stat(to)) != nil { throw RemoteError.alreadyExists(to) }
            throw error
        }
    }

    public func delete(_ item: RemoteItem) async throws {
        if item.kind == .directory {
            try await call(item.path) { try await sftp.rmdir(at: item.path) }
        } else {
            try await call(item.path) { try await sftp.remove(at: item.path) }
        }
    }

    public func close() async {
        try? await sftp.close()
        try? await ssh.client.close()
    }

    // MARK: Streaming

    /// Keeps up to `window` reads in flight, writes results in order; short reads are refilled.
    private static func pipelinedRead(_ file: FileBox, size: Int64?, out: FileHandle, progress: RemoteProgress?) async throws {
        var offset: Int64 = 0 // next byte to write locally
        var nextRequest: Int64 = 0
        var inFlight: [(offset: Int64, task: Task<ByteBuffer, Error>)] = []
        defer { inFlight.forEach { $0.task.cancel() } }

        func enqueue() {
            let at = nextRequest
            inFlight.append((at, Task { try await file.file.read(from: UInt64(at), length: readChunk) }))
            nextRequest += Int64(readChunk)
        }

        progress?(0, size)
        guard let size else {
            // Unknown size: sequential until EOF.
            while true {
                try Task.checkCancellation()
                let buf = try await file.file.read(from: UInt64(offset), length: readChunk)
                if buf.readableBytes == 0 { return }
                try out.write(contentsOf: buf.readableBytesView)
                offset += Int64(buf.readableBytes)
                progress?(offset, nil)
            }
        }
        while nextRequest < size, inFlight.count < window { enqueue() }
        while offset < size {
            try Task.checkCancellation()
            guard !inFlight.isEmpty else { enqueue(); continue }
            let head = inFlight.removeFirst()
            var buf = try await head.task.value
            if head.offset != offset { continue } // stale after a refill; data already written
            if buf.readableBytes == 0 { break } // file shrank
            try out.write(contentsOf: buf.readableBytesView)
            offset += Int64(buf.readableBytes)
            // Short read: fetch the gap before the next queued chunk.
            while offset < min(head.offset + Int64(readChunk), size) {
                try Task.checkCancellation()
                buf = try await file.file.read(from: UInt64(offset), length: UInt32(min(head.offset + Int64(readChunk), size) - offset))
                if buf.readableBytes == 0 { break }
                try out.write(contentsOf: buf.readableBytesView)
                offset += Int64(buf.readableBytes)
            }
            progress?(offset, size)
            if nextRequest < size { enqueue() }
        }
        // The file may have grown since stat: drain the rest sequentially.
        while true {
            try Task.checkCancellation()
            let buf = try await file.file.read(from: UInt64(offset), length: readChunk)
            if buf.readableBytes == 0 { break }
            try out.write(contentsOf: buf.readableBytesView)
            offset += Int64(buf.readableBytes)
            progress?(offset, max(size, offset))
        }
    }

    /// Reads the local file chunk by chunk and keeps up to `window` writes in flight.
    private static func pipelinedWrite(_ file: FileBox, input: FileHandle, total: Int64?, progress: RemoteProgress?) async throws {
        var offset: Int64 = 0
        var done: Int64 = 0
        var inFlight: [(length: Int, task: Task<Void, Error>)] = []
        defer { inFlight.forEach { $0.task.cancel() } }
        progress?(0, total)
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: writeChunk) ?? Data()
            if data.isEmpty { break }
            let at = offset
            let buffer = ByteBuffer(bytes: data)
            inFlight.append((data.count, Task { try await file.file.write(buffer, at: UInt64(at)) }))
            offset += Int64(data.count)
            if inFlight.count >= window {
                let head = inFlight.removeFirst()
                try await head.task.value
                done += Int64(head.length)
                progress?(done, total)
            }
        }
        while !inFlight.isEmpty {
            try Task.checkCancellation()
            let head = inFlight.removeFirst()
            try await head.task.value
            done += Int64(head.length)
            progress?(done, total)
        }
    }

    // MARK: Mapping

    private func call<T>(_ path: String?, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    static func mapError(_ error: Error, path: String?) -> Error {
        switch error {
        case is RemoteError, is CancellationError:
            return error
        case let status as SFTPMessage.Status:
            return mapStatus(status.errorCode, message: status.message, path: path)
        case SFTPError.errorStatus(let status):
            return mapStatus(status.errorCode, message: status.message, path: path)
        case SFTPError.connectionClosed:
            return RemoteError.connectionFailed("Spojenie so serverom sa prerušilo.")
        case is AuthenticationFailed:
            return RemoteError.authenticationFailed
        case let e as SSHClientError:
            switch e {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
                return RemoteError.authenticationFailed
            case .channelCreationFailed:
                return RemoteError.connectionFailed("SFTP kanál sa nepodarilo otvoriť.")
            }
        case let e as ChannelError:
            if case .connectTimeout = e { return RemoteError.connectionFailed("Vypršal časový limit pripojenia.") }
            return RemoteError.connectionFailed(String(describing: e))
        case let e as IOError:
            return RemoteError.connectionFailed(e.description)
        default:
            let text = String(describing: error)
            if text.contains("NIOConnectionError") || text.contains("connectionRefused") || text.contains("DNS") {
                return RemoteError.connectionFailed(text)
            }
            return RemoteError.protocolError(text)
        }
    }

    static func mapStatus(_ code: SFTPStatusCode, message: String, path: String?) -> RemoteError {
        let p = path ?? ""
        switch code {
        case .noSuchFile: return .notFound(p)
        case .permissionDenied: return .permissionDenied(p)
        case .noConnection, .connectionLost: return .connectionFailed(message)
        default:
            let m = message.isEmpty ? "SFTP chyba \(code.rawValue)" : message
            return .protocolError(p.isEmpty ? m : "\(m): \(p)")
        }
    }

    static func item(path: String, name: String, attributes a: SFTPFileAttributes, longname: String?) -> RemoteItem {
        var kind = RemoteItem.Kind.file
        if let mode = a.permissions {
            switch mode & 0o170000 {
            case 0o040000: kind = .directory
            case 0o120000: kind = .symlink
            default: kind = .file
            }
        } else if let first = longname?.first {
            kind = first == "d" ? .directory : (first == "l" ? .symlink : .file)
        }
        return RemoteItem(
            path: path, name: name, kind: kind,
            size: kind == .directory ? nil : a.size.map { Int64($0) },
            modified: a.accessModificationTime?.modificationTime,
            permissions: a.permissions.map { FTPListingParser.permissionString(mode: Int($0)) })
    }
}

// MARK: - Host key validation

/// Validates the server key against `KnownHosts`. Rejections are remembered so the caller can
/// rethrow the precise `RemoteError` even if the SSH stack wraps the failure.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let knownHosts: KnownHosts
    private let rejected = Mutex<RemoteError?>(nil)

    init(host: String, port: Int, knownHosts: KnownHosts) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
    }

    var rejection: RemoteError? { rejected.withLock { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let actual = KnownHosts.fingerprint(openSSHPublicKey: String(openSSHPublicKey: hostKey)) ?? "?"
        switch knownHosts.fingerprint(host: host, port: port) {
        case actual?:
            validationCompletePromise.succeed(())
        case nil:
            fail(.unknownHostKey(host: host, port: port, fingerprint: actual), validationCompletePromise)
        case let expected?:
            fail(.hostKeyMismatch(host: host, port: port, expected: expected, actual: actual), validationCompletePromise)
        }
    }

    private func fail(_ error: RemoteError, _ promise: EventLoopPromise<Void>) {
        rejected.withLock { $0 = error }
        promise.fail(error)
    }
}

// MARK: - Sendable boxes

/// `SSHClient` is not Sendable; it is only used for `close()` after construction.
private final class SSHBox: @unchecked Sendable {
    let client: SSHClient
    init(client: SSHClient) { self.client = client }
}

/// `SFTPFile` is not Sendable; concurrent `read`/`write` calls only send independent requests.
private final class FileBox: @unchecked Sendable {
    let file: SFTPFile
    init(file: SFTPFile) { self.file = file }
}
