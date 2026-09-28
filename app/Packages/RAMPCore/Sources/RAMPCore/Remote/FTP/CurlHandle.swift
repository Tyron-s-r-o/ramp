import CCurl
import Foundation
import Synchronization

/// Set from `onCancel`, polled by curl's progress callback (non-zero return aborts the transfer).
final class CurlCancelFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}

/// Per-perform state reachable from the C callbacks through an opaque pointer.
final class CurlTransferContext {
    let cancel: CurlCancelFlag
    var progress: RemoteProgress?
    var knownTotal: Int64?
    var isUpload = false
    /// Download target (-1 = collect into `memory`).
    var writeFD: Int32 = -1
    var memory = Data()
    var readFD: Int32 = -1
    var writeFailed = false
    /// FTP control-channel replies (`HEADERFUNCTION`), most recent last.
    var replies: [String] = []
    let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE) + 1)

    init(cancel: CurlCancelFlag) {
        self.cancel = cancel
        errorBuffer.initialize(repeating: 0, count: Int(CURL_ERROR_SIZE) + 1)
    }

    deinit { errorBuffer.deallocate() }

    var errorText: String { String(cString: errorBuffer) }
    var lastReply: String { replies.last(where: { $0.first?.isNumber == true }) ?? "" }
}

/// One libcurl easy handle. Every call happens on `queue` (serial), never on the Swift
/// cooperative pool; the handle keeps the FTP control connection alive between performs.
final class CurlHandle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sk.tyron.ramp.ftp-curl")
    private var handle: UnsafeMutableRawPointer?

    private static let globalInit: Void = { curl_global_init(3) }() // CURL_GLOBAL_ALL

    init() {
        _ = Self.globalInit
        handle = curl_easy_init()
    }

    deinit {
        if let handle { curl_easy_cleanup(handle) }
    }

    /// Runs `body` on the serial curl queue; Task cancellation flips the flag the progress
    /// callback polls, so a running transfer aborts promptly.
    func run<T: Sendable>(_ body: @escaping @Sendable (UnsafeMutableRawPointer, CurlCancelFlag) throws -> T) async throws -> T {
        let flag = CurlCancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                queue.async {
                    guard !flag.isSet else { return cont.resume(throwing: CancellationError()) }
                    guard let h = self.handle else {
                        return cont.resume(throwing: RemoteError.connectionFailed("Spojenie je zatvorené."))
                    }
                    cont.resume(with: Result { try body(h, flag) })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// Sends QUIT (via cleanup) and releases the handle.
    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let h = self.handle { curl_easy_cleanup(h) }
                self.handle = nil
                cont.resume()
            }
        }
    }
}

// MARK: - Option helpers (call on the curl queue only)

enum Curl {
    static func set(_ h: UnsafeMutableRawPointer, _ o: CURLoption, _ v: Int) {
        _ = ramp_curl_setopt_long(h, o, v)
    }

    static func set(_ h: UnsafeMutableRawPointer, _ o: CURLoption, _ s: String) {
        _ = s.withCString { ramp_curl_setopt_str(h, o, $0) } // libcurl copies string options
    }

    static func set(_ h: UnsafeMutableRawPointer, _ o: CURLoption, off v: Int64) {
        _ = ramp_curl_setopt_off(h, o, curl_off_t(v))
    }

    static func responseCode(_ h: UnsafeMutableRawPointer) -> Int {
        var code = 0
        _ = ramp_curl_getinfo_long(h, CURLINFO_RESPONSE_CODE, &code)
        return code
    }

    static func entryPath(_ h: UnsafeMutableRawPointer) -> String? {
        var p: UnsafeMutablePointer<CChar>?
        guard ramp_curl_getinfo_str(h, CURLINFO_FTP_ENTRY_PATH, &p) == CURLE_OK, let p else { return nil }
        return String(cString: p)
    }

    /// Installs the callbacks + context; the caller must keep `ctx` alive during perform.
    static func attach(_ h: UnsafeMutableRawPointer, _ ctx: CurlTransferContext) {
        let raw = Unmanaged.passUnretained(ctx).toOpaque()
        _ = ramp_curl_setopt_ptr(h, CURLOPT_ERRORBUFFER, ctx.errorBuffer)
        _ = ramp_curl_setopt_write(h, CURLOPT_HEADERFUNCTION, headerCallback)
        _ = ramp_curl_setopt_ptr(h, CURLOPT_HEADERDATA, raw)
        _ = ramp_curl_setopt_write(h, CURLOPT_WRITEFUNCTION, writeCallback)
        _ = ramp_curl_setopt_ptr(h, CURLOPT_WRITEDATA, raw)
        _ = ramp_curl_setopt_read(h, CURLOPT_READFUNCTION, readCallback)
        _ = ramp_curl_setopt_ptr(h, CURLOPT_READDATA, raw)
        _ = ramp_curl_setopt_xferinfo(h, CURLOPT_XFERINFOFUNCTION, progressCallback)
        _ = ramp_curl_setopt_ptr(h, CURLOPT_XFERINFODATA, raw)
        set(h, CURLOPT_NOPROGRESS, 0)
    }

    /// Builds a curl string list; free with `curl_slist_free_all`.
    static func slist(_ items: [String]) -> UnsafeMutablePointer<curl_slist>? {
        var list: UnsafeMutablePointer<curl_slist>?
        for item in items { list = item.withCString { curl_slist_append(list, $0) } }
        return list
    }

    static func strerror(_ code: CURLcode) -> String { String(cString: curl_easy_strerror(code)) }

    // MARK: C callbacks

    private static func context(_ p: UnsafeMutableRawPointer?) -> CurlTransferContext {
        Unmanaged<CurlTransferContext>.fromOpaque(p!).takeUnretainedValue()
    }

    private static let headerCallback: curl_write_callback = { ptr, size, n, user in
        let count = size * n
        guard let ptr else { return count }
        let ctx = context(user)
        let data = Data(bytes: ptr, count: count)
        let line = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .newlines)
        ctx.replies.append(line)
        if ctx.replies.count > 40 { ctx.replies.removeFirst(ctx.replies.count - 40) }
        return count
    }

    private static let writeCallback: curl_write_callback = { ptr, size, n, user in
        let count = size * n
        guard let ptr else { return 0 }
        let ctx = context(user)
        if ctx.writeFD < 0 {
            ctx.memory.append(UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }
        var written = 0
        while written < count {
            let r = Foundation.write(ctx.writeFD, ptr + written, count - written)
            if r < 0 {
                if errno == EINTR { continue }
                ctx.writeFailed = true
                return 0
            }
            written += r
        }
        return count
    }

    private static let readCallback: curl_read_callback = { ptr, size, n, user in
        guard let ptr else { return 0 }
        let ctx = context(user)
        if ctx.cancel.isSet { return Int(CURL_READFUNC_ABORT) }
        while true {
            let r = Foundation.read(ctx.readFD, ptr, size * n)
            if r < 0, errno == EINTR { continue }
            return r < 0 ? Int(CURL_READFUNC_ABORT) : r
        }
    }

    private static let progressCallback: curl_xferinfo_callback = { user, dlTotal, dlNow, ulTotal, ulNow in
        let ctx = context(user)
        if ctx.cancel.isSet { return 1 }
        if let progress = ctx.progress {
            let now = ctx.isUpload ? ulNow : dlNow
            let total = ctx.isUpload ? ulTotal : dlTotal
            progress(Int64(now), total > 0 ? Int64(total) : ctx.knownTotal)
        }
        return 0
    }
}
