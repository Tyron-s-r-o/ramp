import Foundation
import Synchronization

/// Byte progress of one package download (carried by `InstallProgress.download` / `UpdateProgress.downloadingBytes`).
public struct DownloadProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    /// From the response's `expectedContentLength`, else the manifest size; nil when unknown.
    public var totalBytes: Int64?
    /// Moving average over the last few seconds; nil until enough samples exist.
    public var bytesPerSecond: Double?

    public init(bytesReceived: Int64, totalBytes: Int64?, bytesPerSecond: Double? = nil) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// 0…1, nil when the total is unknown.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }

    /// Seconds left at the current speed (rounded up); nil without total or speed.
    public var secondsRemaining: Int? {
        guard let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let left = max(0, totalBytes - bytesReceived)
        let seconds = (Double(left) / bytesPerSecond).rounded(.up)
        guard seconds.isFinite, seconds < Double(Int32.max) else { return nil }
        return Int(seconds)
    }

    // MARK: Formatting (locale-aware pieces; the sentence itself is localized by the app)

    /// "412,3 MB" (decimal file style, like Finder).
    public static func bytes(_ count: Int64, locale: Locale = .current) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }

    /// "11,2 MB" per second (the "/s" suffix is added by the caller's localized string).
    public static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        bytes(Int64(bytesPerSecond.rounded()), locale: locale)
    }

    /// "0:23", "12:05", "1:02:03".
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Turns raw byte counts into throttled `DownloadProgress` snapshots: speed = moving average over `window`
/// seconds, at most one snapshot per `minInterval` (plus always the final one). Time is injected for tests.
public struct DownloadRateTracker: Sendable {
    public let totalBytes: Int64?
    public let window: TimeInterval
    public let minInterval: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastEmit: TimeInterval?

    public init(totalBytes: Int64?, window: TimeInterval = 5, minInterval: TimeInterval = 0.2) {
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.window = window
        self.minInterval = minInterval
    }

    /// Records `bytes` received so far at `time`; returns a snapshot unless throttled. `expected` (the
    /// response's content length, if known) overrides the initial total.
    public mutating func record(bytes: Int64, expected: Int64? = nil, at time: TimeInterval,
                                force: Bool = false) -> DownloadProgress? {
        samples.append((time, bytes))
        // Keep one sample older than the window as the baseline.
        while samples.count > 2, samples[1].time <= time - window { samples.removeFirst() }
        let total = expected.flatMap { $0 > 0 ? $0 : nil } ?? totalBytes
        let done = total.map { bytes >= $0 } ?? false
        if !force, !done, let lastEmit, time - lastEmit < minInterval { return nil }
        lastEmit = time
        return DownloadProgress(bytesReceived: bytes, totalBytes: total, bytesPerSecond: speed)
    }

    /// Bytes/s over the retained samples; nil below 0.5 s of data.
    public var speed: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let dt = last.time - first.time
        guard dt >= 0.5 else { return nil }
        return Double(max(0, last.bytes - first.bytes)) / dt
    }
}

/// URLSession download delegate: moves the finished file to `destination`, reports throttled byte progress.
final class PackageDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var tracker: DownloadRateTracker
        var continuation: CheckedContinuation<Void, any Error>?
        var failure: (any Error)?
        var moved = false
    }

    private let destination: URL
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let state: Mutex<State>

    init(destination: URL, totalBytes: Int64?, onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        state = Mutex(State(tracker: DownloadRateTracker(totalBytes: totalBytes)))
    }

    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let snapshot = state.withLock {
            $0.tracker.record(bytes: totalBytesWritten, expected: totalBytesExpectedToWrite, at: Self.now)
        }
        if let snapshot { onProgress(snapshot) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns → move it now.
        var failure: (any Error)?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = InstallError.downloadFailed(url: downloadTask.originalRequest?.url?.absoluteString ?? "",
                                                  reason: "HTTP \(http.statusCode)")
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size]
            as? NSNumber)?.int64Value
        let snapshot: DownloadProgress? = state.withLock {
            $0.failure = failure
            $0.moved = failure == nil
            guard failure == nil, let size else { return nil }
            return $0.tracker.record(bytes: size, expected: size, at: Self.now, force: true)
        }
        if let snapshot { onProgress(snapshot) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result): (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) = state.withLock {
            let c = $0.continuation
            $0.continuation = nil
            if let error { return (c, .failure(error)) }
            if let failure = $0.failure { return (c, .failure(failure)) }
            if !$0.moved { return (c, .failure(URLError(.cannotCreateFile))) }
            return (c, .success(()))
        }
        continuation?.resume(with: result)
    }
}
