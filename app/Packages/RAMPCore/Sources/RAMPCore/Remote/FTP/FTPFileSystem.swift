import CCurl
import Foundation
import Synchronization

/// FTP / FTPES / FTPS session over the macOS system libcurl. One easy handle per session, so the
/// control connection (and its TLS session) is reused between operations; operations are
/// serialized on the handle's queue. Paths are always absolute (`%2F`-prefixed URLs, NOCWD for
/// files, SINGLECWD for listings).
public final class FTPFileSystem: RemoteFileSystem {
    private let site: RemoteSite
    private let password: String
    private let curl = CurlHandle()
    private let state = Mutex(State())

    private struct State {
        var entryPath: String?
        var mlsdUnsupported = false
    }

    private init(site: RemoteSite, password: String) {
        self.site = site
        self.password = password
    }

    /// Connects and logs in (errors surface here, e.g. `.authenticationFailed`,
    /// `.certificateUntrusted`).
    public static func connect(site: RemoteSite, secrets: SiteSecrets?) async throws -> FTPFileSystem {
        guard site.proto != .sftp else { throw RemoteError.protocolError("FTPFileSystem nepodporuje SFTP.") }
        // Anonymous FTP when no password is stored and the user is "anonymous"/"ftp".
        let anonymous = ["anonymous", "ftp"].contains(site.username.lowercased())
        guard let password = secrets?.password ?? (anonymous ? "ramp@localhost" : nil) else {
            throw RemoteError.missingSecret
        }
        let fs = FTPFileSystem(site: site, password: password)
        let entry = try await fs.perform(url: fs.url(nil), path: nil, method: CURLFTPMETHOD_NOCWD) { h, _ in
            Curl.set(h, CURLOPT_NOBODY, 1)
            // Ask for UTF-8 names; "*" = ignore failure (servers that are UTF-8 anyway or don't care).
            return Curl.slist(["*OPTS UTF8 ON"])
        } after: { h, _ in
            Curl.entryPath(h)
        }
        fs.state.withLock { $0.entryPath = entry }
        return fs
    }

    // MARK: RemoteFileSystem

    public func homeDirectory() async throws -> String {
        if let p = site.initialPath, !p.isEmpty { return p.hasPrefix("/") ? p : "/" + p }
        if let entry = state.withLock({ $0.entryPath }), entry.hasPrefix("/") { return entry }
        return "/"
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        if !state.withLock({ $0.mlsdUnsupported }) {
            do {
                let text = try await listing(path, command: "MLSD")
                return FTPListingParser.parseMLSD(text, directory: path)
            } catch FTPCommandUnsupported.command {
                state.withLock { $0.mlsdUnsupported = true }
            }
        }
        do {
            return FTPListingParser.parseLIST(try await listing(path, command: "LIST -a"), directory: path)
        } catch FTPCommandUnsupported.command {
            return FTPListingParser.parseLIST(try await listing(path, command: "LIST"), directory: path)
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        if path == "/" { return RemoteItem(path: "/", name: "/", kind: .directory) }
        let name = RemotePath.name(path)
        do {
            return try await list(RemotePath.parent(path)).first { $0.name == name }
        } catch RemoteError.notFound {
            return nil
        }
    }

    public func download(_ remotePath: String, to localURL: URL, progress: RemoteProgress?) async throws {
        let tmp = localURL.deletingLastPathComponent()
            .appending(path: ".\(localURL.lastPathComponent).ramp-\(UUID().uuidString).part")
        let fd = open(tmp.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw RemoteError.permissionDenied(localURL.path(percentEncoded: false)) }
        do {
            try await perform(url: url(remotePath), path: remotePath, method: CURLFTPMETHOD_NOCWD) { _, ctx in
                ctx.writeFD = fd
                ctx.progress = progress
                return nil
            }
            _ = Foundation.close(fd)
            _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tmp)
        } catch {
            _ = Foundation.close(fd)
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, progress: RemoteProgress?) async throws {
        let fd = open(localURL.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { throw RemoteError.notFound(localURL.path(percentEncoded: false)) }
        defer { _ = Foundation.close(fd) }
        var st = Foundation.stat()
        let size: Int64? = fstat(fd, &st) == 0 ? Int64(st.st_size) : nil
        try await perform(url: url(remotePath), path: remotePath, method: CURLFTPMETHOD_NOCWD) { h, ctx in
            Curl.set(h, CURLOPT_UPLOAD, 1)
            if let size { Curl.set(h, CURLOPT_INFILESIZE_LARGE, off: size) }
            ctx.readFD = fd
            ctx.isUpload = true
            ctx.knownTotal = size
            ctx.progress = progress
            return nil
        }
    }

    public func createDirectory(_ path: String) async throws {
        try await quote(["MKD \(try Self.wire(path))"], path: path)
    }

    public func rename(_ from: String, to: String) async throws {
        try await quote(["RNFR \(try Self.wire(from))", "RNTO \(try Self.wire(to))"], path: from)
    }

    public func delete(_ item: RemoteItem) async throws {
        let verb = item.kind == .directory ? "RMD" : "DELE"
        try await quote(["\(verb) \(try Self.wire(item.path))"], path: item.path)
    }

    public func close() async {
        await curl.close()
    }

    // MARK: Operations

    private enum FTPCommandUnsupported: Error { case command }

    private func listing(_ path: String, command: String) async throws -> String {
        let dirURL = url(path, directory: true)
        do {
            let data = try await performRaw(url: dirURL, path: path, method: CURLFTPMETHOD_SINGLECWD) { h, _ in
                Curl.set(h, CURLOPT_CUSTOMREQUEST, command)
                return nil
            } after: { _, ctx in
                ctx.memory
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        } catch let failure as FTPFailure {
            // 500/501/502/504: command unknown / not implemented → caller falls back.
            if [500, 501, 502, 504].contains(failure.reply), !failure.duringCWD { throw FTPCommandUnsupported.command }
            throw failure.error
        }
    }

    private func quote(_ commands: [String], path: String) async throws {
        try await perform(url: url(nil), path: path, method: CURLFTPMETHOD_NOCWD) { h, _ in
            Curl.set(h, CURLOPT_NOBODY, 1)
            return Curl.slist(commands)
        }
    }

    /// Paths go on the control channel verbatim — CR/LF would inject commands.
    private static func wire(_ path: String) throws -> String {
        guard !path.contains("\r"), !path.contains("\n") else { throw RemoteError.protocolError("Neplatný názov: \(path)") }
        return path
    }

    // MARK: URL building

    /// `ftp://host:port/%2Fdir/file` (absolute path). nil = server root URL without a path.
    func url(_ path: String?, directory: Bool = false) -> String {
        let scheme = site.proto == .ftps ? "ftps" : "ftp"
        let host = site.host.contains(":") && !site.host.hasPrefix("[") ? "[\(site.host)]" : site.host
        var s = "\(scheme)://\(host):\(site.port)/"
        guard let path else { return s }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map { Self.encode(String($0)) }
        s += "%2F" + comps.joined(separator: "/")
        if directory { s += "/" }
        return s
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    // MARK: Perform

    /// Error with the raw FTP reply, used internally before mapping to `RemoteError`.
    private struct FTPFailure: Error {
        let error: Error
        let reply: Int
        let duringCWD: Bool
    }

    private typealias Configure = @Sendable (UnsafeMutableRawPointer, CurlTransferContext) -> UnsafeMutablePointer<curl_slist>?

    private func perform(url: String, path: String?, method: curl_ftpmethod, configure: @escaping Configure) async throws {
        try await perform(url: url, path: path, method: method, configure: configure) { _, _ in () }
    }

    private func perform<T: Sendable>(url: String, path: String?, method: curl_ftpmethod, configure: @escaping Configure,
                                      after: @escaping @Sendable (UnsafeMutableRawPointer, CurlTransferContext) -> T) async throws -> T {
        do {
            return try await performRaw(url: url, path: path, method: method, configure: configure, after: after)
        } catch let failure as FTPFailure {
            throw failure.error
        }
    }

    /// One `curl_easy_perform` on the handle queue; failures come back as `FTPFailure`.
    private func performRaw<T: Sendable>(url: String, path: String?, method: curl_ftpmethod, configure: @escaping Configure,
                                         after: @escaping @Sendable (UnsafeMutableRawPointer, CurlTransferContext) -> T) async throws -> T {
        let site = self.site
        let password = self.password
        return try await curl.run { h, cancel in
            let ctx = CurlTransferContext(cancel: cancel)
            curl_easy_reset(h) // keeps the live connection and TLS session cache
            Self.applyBase(h, site: site, password: password, method: method)
            Curl.set(h, CURLOPT_URL, url)
            Curl.attach(h, ctx)
            let list = configure(h, ctx)
            if let list { _ = ramp_curl_setopt_slist(h, CURLOPT_QUOTE, list) }
            defer { if let list { curl_slist_free_all(list) } }

            let rc = withExtendedLifetime(ctx) { curl_easy_perform(h) }
            if rc == CURLE_OK { return after(h, ctx) }
            if cancel.isSet { throw CancellationError() }
            let reply = Curl.responseCode(h)
            throw FTPFailure(error: Self.mapError(rc, reply: reply, ctx: ctx, path: path), reply: reply,
                             duringCWD: rc == CURLE_REMOTE_ACCESS_DENIED)
        }
    }

    private static func applyBase(_ h: UnsafeMutableRawPointer, site: RemoteSite, password: String, method: curl_ftpmethod) {
        Curl.set(h, CURLOPT_NOSIGNAL, 1)
        Curl.set(h, CURLOPT_USERNAME, site.username)
        Curl.set(h, CURLOPT_PASSWORD, password)
        Curl.set(h, CURLOPT_CONNECTTIMEOUT, 20)
        Curl.set(h, CURLOPT_SERVER_RESPONSE_TIMEOUT, 60)
        // Abort a stalled transfer (< 1 byte/s for 60 s) instead of hanging forever.
        Curl.set(h, CURLOPT_LOW_SPEED_LIMIT, 1)
        Curl.set(h, CURLOPT_LOW_SPEED_TIME, 60)
        Curl.set(h, CURLOPT_FTP_FILEMETHOD, Int(method.rawValue))
        Curl.set(h, CURLOPT_FTP_CREATE_MISSING_DIRS, 0)
        if site.proto == .ftpes || site.proto == .ftps {
            Curl.set(h, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
        }
        if site.allowInsecureCertificate {
            Curl.set(h, CURLOPT_SSL_VERIFYPEER, 0)
            Curl.set(h, CURLOPT_SSL_VERIFYHOST, 0)
        }
        if !site.passive { Curl.set(h, CURLOPT_FTPPORT, "-") }
    }

    // MARK: Error mapping

    static func mapError(_ rc: CURLcode, reply: Int, ctx: CurlTransferContext, path: String?) -> Error {
        let p = path ?? ""
        let detail = [ctx.errorText, ctx.lastReply].filter { !$0.isEmpty }.joined(separator: " — ")
        let message = detail.isEmpty ? Curl.strerror(rc) : detail
        if ctx.writeFailed { return RemoteError.permissionDenied("lokálny zápis zlyhal") }

        switch rc {
        case CURLE_LOGIN_DENIED:
            return RemoteError.authenticationFailed
        case CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CERTPROBLEM, CURLE_SSL_CACERT_BADFILE,
             CURLE_SSL_ISSUER_ERROR, CURLE_SSL_PINNEDPUBKEYNOTMATCH, CURLE_SSL_INVALIDCERTSTATUS:
            return RemoteError.certificateUntrusted(message)
        case CURLE_SSL_CONNECT_ERROR:
            let t = message.lowercased()
            if t.contains("cert") || t.contains("trust") || t.contains("verif") {
                return RemoteError.certificateUntrusted(message)
            }
            return RemoteError.connectionFailed(message)
        case CURLE_USE_SSL_FAILED:
            return RemoteError.connectionFailed("Server nepodporuje TLS (AUTH TLS). \(message)")
        case CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_CONNECT, CURLE_OPERATION_TIMEDOUT,
             CURLE_RECV_ERROR, CURLE_SEND_ERROR, CURLE_GOT_NOTHING, CURLE_FTP_ACCEPT_FAILED,
             CURLE_FTP_ACCEPT_TIMEOUT, CURLE_FTP_CANT_GET_HOST, CURLE_FTP_WEIRD_PASV_REPLY,
             CURLE_FTP_WEIRD_227_FORMAT, CURLE_FTP_PORT_FAILED, CURLE_COULDNT_RESOLVE_PROXY:
            return RemoteError.connectionFailed(message)
        case CURLE_REMOTE_FILE_NOT_FOUND:
            return RemoteError.notFound(p)
        case CURLE_WRITE_ERROR:
            return RemoteError.permissionDenied("lokálny zápis zlyhal")
        case CURLE_READ_ERROR:
            return RemoteError.protocolError("Lokálny súbor sa nedá čítať.")
        default:
            break
        }
        if reply == 530 { return RemoteError.authenticationFailed }
        if (400..<600).contains(reply) {
            let t = ctx.lastReply.lowercased()
            if t.contains("exist"), !t.contains("not exist"), !t.contains("n't exist") {
                return RemoteError.alreadyExists(p)
            }
            if t.contains("no such") || t.contains("not found") || t.contains("not exist") || t.contains("n't exist") {
                return RemoteError.notFound(p)
            }
            if [550, 553, 532, 450].contains(reply) {
                return RemoteError.permissionDenied(p.isEmpty ? message : "\(p) (\(ctx.lastReply))")
            }
        }
        return RemoteError.protocolError(message)
    }
}
